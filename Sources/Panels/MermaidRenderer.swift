import AppKit
import CryptoKit

/// Renders Mermaid diagram code to images via the `mmdc` CLI tool.
/// Falls back gracefully when mmdc is not installed.
final class MermaidRenderer: FencedCodeRenderer {
    static let shared = MermaidRenderer()

    let languageTag = "mermaid"

    @MainActor var installHint: String? {
        String(localized: "markdown.mermaid.installHint",
               defaultValue: "Install @mermaid-js/mermaid-cli for diagram rendering")
    }

    /// Maximum input size (50 KB) to prevent runaway rendering.
    private static let maxInputBytes = 50 * 1024
    /// Timeout for each mmdc invocation.
    private static let renderTimeout: TimeInterval = 15
    /// Grace period after SIGTERM before SIGKILL.
    private static let killGracePeriod: TimeInterval = 2
    /// Re-check mmdc availability after this many seconds.
    private static let mmdcCheckTTL: TimeInterval = 60
    /// Maximum cache size in bytes (100 MB).
    private static let maxCacheBytes: UInt64 = 100 * 1024 * 1024

    private let cacheDirectory: URL
    /// All access to mmdcPath/mmdcCheckedAt is serialized through `queue`.
    private var mmdcPath: String?
    private var mmdcCheckedAt: Date?
    private let queue = DispatchQueue(label: "com.cmux.mermaid-renderer", qos: .userInitiated)

    /// In-flight render processes keyed by cache key. Access only on `queue`.
    private var inFlightProcesses: [String: Process] = [:]

    /// Published on main thread so SwiftUI can observe without calling resolveMmdc directly.
    @MainActor private(set) var isAvailable: Bool = false

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("com.cmux.mermaid", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Resolve mmdc asynchronously on init so isAvailable is populated without blocking.
        queue.async { [self] in
            let available = resolveMmdc() != nil
            DispatchQueue.main.async { self.isAvailable = available }
        }
    }

    /// Extended PATH entries for finding node/npm-installed binaries.
    private static var extendedPath: String {
        var paths = ["/usr/local/bin", "/opt/homebrew/bin"]
        // Resolve actual nvm node version bin directories
        let nvmBase = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            for version in versions where version.hasPrefix("v") {
                paths.append("\(nvmBase)/\(version)/bin")
            }
        }
        if let existing = ProcessInfo.processInfo.environment["PATH"] {
            return paths.joined(separator: ":") + ":" + existing
        }
        return paths.joined(separator: ":")
    }

    /// Resolve the mmdc binary path, with TTL-based re-checking.
    /// MUST be called on `queue` only.
    private func resolveMmdc() -> String? {
        if let checkedAt = mmdcCheckedAt {
            // If we found it before, use it. If not, re-check after TTL.
            if mmdcPath != nil { return mmdcPath }
            if Date().timeIntervalSince(checkedAt) < Self.mmdcCheckTTL { return nil }
        }
        mmdcCheckedAt = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["mmdc"]
        // Use the extended PATH so which can find mmdc in Homebrew/nvm locations
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.extendedPath
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    mmdcPath = path
                    DispatchQueue.main.async { self.isAvailable = true }
                }
            }
        } catch {}
        return mmdcPath
    }

    /// Cache key from content hash and theme.
    private func cacheKey(code: String, isDark: Bool) -> String {
        let input = code + (isDark ? ":dark" : ":light")
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Cancel all in-flight render processes. Call on `queue`.
    private func cancelInFlightRenders() {
        for (key, process) in inFlightProcesses {
            if process.isRunning {
                process.terminate()
            }
            inFlightProcesses.removeValue(forKey: key)
        }
    }

    /// Cancel in-flight renders for keys not in the given set. Call on `queue`.
    func cancelRendersExcept(activeKeys: Set<String>) {
        queue.async { [self] in
            for (key, process) in inFlightProcesses {
                if !activeKeys.contains(key) {
                    if process.isRunning { process.terminate() }
                    inFlightProcesses.removeValue(forKey: key)
                }
            }
        }
    }

    /// Generate the cache key for external callers (e.g., MarkdownPanel).
    func renderCacheKey(code: String, isDark: Bool) -> String {
        cacheKey(code: code, isDark: isDark)
    }

    /// Render mermaid code to an NSImage. Returns nil if mmdc is unavailable or rendering fails.
    func render(code: String, isDark: Bool, completion: @escaping (NSImage?) -> Void) {
        queue.async { [self] in
            guard let mmdc = resolveMmdc() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Reject oversized input
            guard code.utf8.count <= Self.maxInputBytes else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let key = cacheKey(code: code, isDark: isDark)
            let cachedPng = cacheDirectory.appendingPathComponent("\(key).png")

            // Check cache
            if FileManager.default.fileExists(atPath: cachedPng.path),
               let image = NSImage(contentsOf: cachedPng) {
                DispatchQueue.main.async { completion(image) }
                return
            }

            // Cancel any existing render for this key
            if let existing = inFlightProcesses[key], existing.isRunning {
                existing.terminate()
            }

            // Write temp input file
            let inputFile = cacheDirectory.appendingPathComponent("\(key).mmd")
            let outputFile = cacheDirectory.appendingPathComponent("\(key)-out.png")
            do {
                try code.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            defer {
                try? FileManager.default.removeItem(at: inputFile)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: mmdc)
            process.arguments = [
                "-i", inputFile.path,
                "-o", outputFile.path,
                "-t", isDark ? "dark" : "default",
                "-b", "transparent",
                "-s", "2"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // Use extended PATH for mmdc's own child processes (e.g. Puppeteer)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Self.extendedPath
            process.environment = env

            process.qualityOfService = .userInitiated

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            inFlightProcesses[key] = process

            // Timeout handling
            let deadline = DispatchTime.now() + Self.renderTimeout
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }

            if group.wait(timeout: deadline) == .timedOut {
                process.terminate()
                // Give a grace period, then force kill
                let killDeadline = DispatchTime.now() + Self.killGracePeriod
                if group.wait(timeout: killDeadline) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                }
                inFlightProcesses.removeValue(forKey: key)
                DispatchQueue.main.async { completion(nil) }
                return
            }

            inFlightProcesses.removeValue(forKey: key)

            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // mmdc may produce output with -1 suffix (e.g. key-out-1.png)
            let altOutputFile = cacheDirectory.appendingPathComponent("\(key)-out-1.png")
            let actualOutput: URL
            if FileManager.default.fileExists(atPath: outputFile.path) {
                actualOutput = outputFile
            } else if FileManager.default.fileExists(atPath: altOutputFile.path) {
                actualOutput = altOutputFile
            } else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Move to cache location
            try? FileManager.default.removeItem(at: cachedPng)
            try? FileManager.default.moveItem(at: actualOutput, to: cachedPng)
            // Clean up alternate if it exists
            try? FileManager.default.removeItem(at: altOutputFile)

            guard let image = NSImage(contentsOf: cachedPng) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Evict old cache entries if over size limit
            evictCacheIfNeeded()

            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - Cache eviction

    /// Evict oldest cached PNGs by access time until under the size limit.
    /// MUST be called on `queue`.
    private func evictCacheIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let pngs = files.filter { $0.pathExtension == "png" }
        var totalSize: UInt64 = 0
        var entries: [(url: URL, size: UInt64, accessed: Date)] = []

        for url in pngs {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]),
                  let size = values.fileSize,
                  let accessed = values.contentAccessDate else { continue }
            let uSize = UInt64(size)
            totalSize += uSize
            entries.append((url, uSize, accessed))
        }

        guard totalSize > Self.maxCacheBytes else { return }

        // Sort oldest-accessed first
        entries.sort { $0.accessed < $1.accessed }

        for entry in entries {
            guard totalSize > Self.maxCacheBytes else { break }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }
}
