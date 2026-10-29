public import Foundation

/// Records one phone at a time: screen video, device log, every input sent
/// through cmux (with its time offset), then notes and a poster frame.
/// Writes `<root>/<id>/{screen.mov|mp4, device-log.ndjson, events.jsonl,
/// notes.md, poster.png, manifest.json}`.
public actor PhoneRecorder {
    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.next.phone.recorder`): its recording file writes block a thread of
    /// its own, never a cooperative pool thread (the HomeCache pattern).
    // executor: com.cmuxterm.next.phone.recorder
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.next.phone.recorder", qos: .utility)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let backend: any PhoneBackend
    private let root: URL
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> Duration
    private let makeID: @Sendable () -> String

    private var current: (recording: PhoneRecording, started: Duration,
                          video: any PhoneRunningCommand, log: (any PhoneRunningCommand)?)?

    /// - Parameters:
    ///   - root: the recordings folder (the App passes its build-scoped state folder).
    ///   - now / uptime / makeID: injected so tests are deterministic.
    public init(backend: any PhoneBackend, root: URL,
                now: @escaping @Sendable () -> Date = Date.init,
                uptime: @escaping @Sendable () -> Duration = { .nanoseconds(Int64(clamping: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))) },
                makeID: @escaping @Sendable () -> String = PhoneRecorder.timestampID) {
        self.backend = backend
        self.root = root
        self.now = now
        self.uptime = uptime
        self.makeID = makeID
    }

    /// The running recording, if any.
    public var active: PhoneRecording? { current?.recording }

    @discardableResult
    public func start(_ device: PhoneDevice) async throws -> PhoneRecording {
        guard current == nil else { throw PhoneError.alreadyRecording }
        let id = makeID()
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = "screen." + backend.videoExtension(for: device.id)
        let videoProcess = try await backend.startVideo(device.id, to: folder.appendingPathComponent(video))
        let wantsLog = backend.capabilities(for: device).contains(.deviceLog)
        let log = wantsLog ? try? await backend.startLog(device.id, to: folder.appendingPathComponent("device-log.ndjson")) : nil
        let recording = PhoneRecording(id: id, device: device, startedAt: now(), video: video,
                                       log: log == nil ? nil : "device-log.ndjson", folder: folder)
        current = (recording, uptime(), videoProcess, log)
        return recording
    }

    /// Logs an input sent to the recorded phone; ignored when not recording
    /// or for another phone.
    public func note(_ input: PhoneInput, on id: PhoneDeviceID) {
        guard var running = current, running.recording.device.id == id else { return }
        running.recording.events.append(PhoneRecordingEvent(at: seconds(since: running.started), input: input))
        current = running
    }

    /// Stops the video and the log (both finalize on SIGINT), takes a poster
    /// frame, writes the notes and the manifest, and returns the recording.
    public func stop(notes: String = "") async throws -> PhoneRecording {
        guard let running = current else { throw PhoneError.notRecording }
        current = nil
        var recording = running.recording
        recording.duration = seconds(since: running.started)
        recording.notes = notes
        await running.video.interrupt()
        await running.log?.interrupt()
        _ = await running.video.waitForExit(deadline: .seconds(15))
        _ = await running.log?.waitForExit(deadline: .seconds(5))
        let poster = recording.folder.appendingPathComponent("poster.png")
        if (try? await backend.screenshot(recording.device.id, to: poster)) != nil,
           FileManager.default.fileExists(atPath: poster.path) {
            recording.poster = "poster.png"
        }
        try write(recording)
        return recording
    }

    /// Reads a recording folder written by ``stop(notes:)``.
    public static func load(_ folder: URL) throws -> PhoneRecording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let key = CodingUserInfoKey.phoneRecordingFolder { decoder.userInfo[key] = folder }
        return try decoder.decode(PhoneRecording.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    /// `20261019-174203-1a2b`: sorts by time, unique enough for one Mac.
    public static let timestampID: @Sendable () -> String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    private func seconds(since start: Duration) -> Double {
        let elapsed = uptime() - start
        let (whole, atto) = elapsed.components
        return (Double(whole) + Double(atto) / 1e18).rounded(toPlaces: 3)
    }

    private func write(_ recording: PhoneRecording) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: recording.folder.appendingPathComponent("manifest.json"), options: .atomic)
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys]
        var lines = Data()
        for event in recording.events {
            lines.append(try lineEncoder.encode(event))
            lines.append(0x0A)
        }
        try lines.write(to: recording.folder.appendingPathComponent("events.jsonl"), options: .atomic)
        try Data(recording.notes.utf8).write(to: recording.folder.appendingPathComponent("notes.md"), options: .atomic)
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
