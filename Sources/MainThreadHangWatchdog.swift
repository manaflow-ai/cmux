import Foundation

struct MainThreadHangWatchdogState {
    let stallThreshold: TimeInterval
    private(set) var lastHeartbeat: TimeInterval?
    private var capturedCurrentStall = false

    init(stallThreshold: TimeInterval) {
        self.stallThreshold = stallThreshold
    }

    mutating func recordHeartbeat(at timestamp: TimeInterval) {
        lastHeartbeat = timestamp
        capturedCurrentStall = false
    }

    mutating func shouldCapture(at timestamp: TimeInterval) -> Bool {
        guard let lastHeartbeat,
              timestamp - lastHeartbeat >= stallThreshold,
              !capturedCurrentStall else {
            return false
        }
        capturedCurrentStall = true
        return true
    }
}

struct MainThreadHangCaptureRetentionPolicy {
    let maximumCaptureCount: Int

    func prepareForNewCapture(in directory: URL, fileManager: FileManager = .default) {
        guard maximumCaptureCount > 0,
              let files = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }

        var newestDateByCapture: [String: Date] = [:]
        for file in files {
            guard let capture = captureIdentifier(for: file.lastPathComponent) else { continue }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values?.contentModificationDate ?? .distantPast
            newestDateByCapture[capture] = max(newestDateByCapture[capture] ?? .distantPast, date)
        }

        let keepExistingCount = maximumCaptureCount - 1
        let staleCaptures = Set(newestDateByCapture
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key > rhs.key
            }
            .dropFirst(keepExistingCount)
            .map(\.key))
        guard !staleCaptures.isEmpty else { return }
        for file in files {
            guard let capture = captureIdentifier(for: file.lastPathComponent),
                  staleCaptures.contains(capture) else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    private func captureIdentifier(for name: String) -> String? {
        for suffix in [".sample.txt", ".metadata.txt"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }
}

/// Detects main-queue starvation from a background timer and captures a stack
/// sample without asking the blocked main thread to participate.
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    private static let stallThreshold: TimeInterval = 8
    private static let heartbeatInterval: TimeInterval = 1
    private static let captureRetention = MainThreadHangCaptureRetentionPolicy(maximumCaptureCount: 8)

    private let monitorQueue = DispatchQueue(
        label: "com.cmuxterm.main-thread-hang-watchdog",
        qos: .utility
    )
    private var state = MainThreadHangWatchdogState(stallThreshold: stallThreshold)
    private var timer: DispatchSourceTimer?
    private var heartbeatQueued = false
    private var activeSamples: [UUID: Process] = [:]
    private let startLock = NSLock()
    private var started = false

    private init() {}

    func start() {
        let shouldStart = startLock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let initialHeartbeat = ProcessInfo.processInfo.systemUptime

        monitorQueue.async { [self] in
            state.recordHeartbeat(at: initialHeartbeat)
            let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
            timer.schedule(
                deadline: .now() + Self.heartbeatInterval,
                repeating: Self.heartbeatInterval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.activate()
            queueHeartbeat()
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if state.shouldCapture(at: now) {
            captureHang(at: now)
        }
        queueHeartbeat()
    }

    /// Keeps at most one heartbeat pending on the main queue. A long stall
    /// therefore does not enqueue hundreds of obsolete callbacks.
    private func queueHeartbeat() {
        guard !heartbeatQueued else { return }
        heartbeatQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timestamp = ProcessInfo.processInfo.systemUptime
            monitorQueue.async { [self] in
                self.state.recordHeartbeat(at: timestamp)
                self.heartbeatQueued = false
            }
        }
    }

    private func captureHang(at timestamp: TimeInterval) {
        guard let lastHeartbeat = state.lastHeartbeat,
              let directory = hangDirectory() else {
            return
        }

        let identifier = UUID()
        Self.captureRetention.prepareForNewCapture(in: directory)
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let baseName = "cmux-hang-\(stamp)-\(ProcessInfo.processInfo.processIdentifier)-\(identifier.uuidString.lowercased())"
        let sampleURL = directory.appendingPathComponent("\(baseName).sample.txt")
        let metadataURL = directory.appendingPathComponent("\(baseName).metadata.txt")
        writeMetadata(
            to: metadataURL,
            sampleURL: sampleURL,
            stallDuration: timestamp - lastHeartbeat
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            "\(ProcessInfo.processInfo.processIdentifier)",
            "5",
            "1",
            "-file",
            sampleURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            monitorQueue.async { [self] in
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: sampleURL.path
                )
                self.activeSamples.removeValue(forKey: identifier)
            }
        }

        do {
            try process.run()
            activeSamples[identifier] = process
        } catch {
            appendSampleLaunchError(error, to: metadataURL)
        }
    }

    private func hangDirectory() -> URL? {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("hangs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return directory
        } catch {
            return nil
        }
    }

    private func writeMetadata(
        to url: URL,
        sampleURL: URL,
        stallDuration: TimeInterval
    ) {
        let processInfo = ProcessInfo.processInfo
        let bundle = Bundle.main
        let appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let appBuild = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let lines = [
            "capturedAt=\(ISO8601DateFormatter().string(from: Date()))",
            "pid=\(processInfo.processIdentifier)",
            "stallSeconds=\(String(format: "%.3f", stallDuration))",
            "systemUptime=\(String(format: "%.3f", processInfo.systemUptime))",
            "appVersion=\(appVersion)",
            "appBuild=\(appBuild)",
            "samplePath=\(sampleURL.path)",
            "",
        ]
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            return
        }
    }

    private func appendSampleLaunchError(_ error: Error, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let line = "sampleLaunchError=\(String(describing: error))\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
