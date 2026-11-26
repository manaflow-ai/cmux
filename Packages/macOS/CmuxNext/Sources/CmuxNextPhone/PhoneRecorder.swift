public import Foundation

/// Records one phone at a time: screen video, device log, every input sent
/// through cmux (with its time offset), then notes and a poster frame.
/// Writes `<root>/<id>/{screen.mov|mp4, device-log.ndjson, events.jsonl,
/// notes.md, poster.png, manifest.json}`.
public actor PhoneRecorder {
    private let backend: any PhoneBackend
    private let root: URL
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> Duration
    private let makeID: @Sendable () -> String

    /// `cmux-phone-core`'s recorder state, and the video and log processes it started.
    private var current: (recorder: PhoneRecorderWire, folder: URL,
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
    public var active: PhoneRecording? { current.map { $0.recorder.recording.recording(in: $0.folder) } }

    @discardableResult
    public func start(_ device: PhoneDevice) async throws -> PhoneRecording {
        let plan = try rules(Plan.self, "recorder_start", ["recorder": PhoneRules.field(current?.recorder), "id": device.id.description,
                                                           "capabilities": backend.capabilities(for: device).rawValue])
        let id = makeID()
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let videoProcess = try await backend.startVideo(device.id, to: folder.appendingPathComponent(plan.video))
        var logProcess: (any PhoneRunningCommand)?
        if let log = plan.log { logProcess = try? await backend.startLog(device.id, to: folder.appendingPathComponent(log)) }
        var begin: [String: Any] = ["id": id, "device": PhoneRules.field(PhoneDeviceReply(device)), "started_at": now().formatted(.iso8601),
                                    "video": plan.video, "uptime_nanos": nanos(uptime())]
        if logProcess != nil, let log = plan.log { begin["log"] = log }
        let recorder = try PhoneRules.decode(PhoneRecorderWire.self, "recorder", "recorder_begin", begin, what: "the recorder")
        current = (recorder, folder, videoProcess, logProcess)
        return recorder.recording.recording(in: folder)
    }

    /// Logs an input sent to the recorded phone; ignored when not recording
    /// or for another phone.
    public func note(_ input: PhoneInput, on id: PhoneDeviceID) {
        guard let running = current,
              let next = try? rules(Noted.self, "recorder_note", ["recorder": PhoneRules.field(running.recorder), "input": input.wire,
                                                                  "device_id": id.description, "uptime_nanos": nanos(uptime())]),
              next.noted, let recorder = next.recorder else { return }
        current?.recorder = recorder
    }

    /// Stops the video and the log (both finalize on SIGINT), takes a poster
    /// frame, writes the notes and the manifest, and returns the recording.
    public func stop(notes: String = "") async throws -> PhoneRecording {
        let stopped = try rules(Stopped.self, "recorder_stop", ["recorder": PhoneRules.field(current?.recorder), "notes": notes,
                                                                "uptime_nanos": nanos(uptime())])
        guard let running = current else { throw PhoneError.notRecording }
        current = nil
        await running.video.interrupt()
        await running.log?.interrupt()
        _ = await running.video.waitForExit(deadline: .seconds(15))
        _ = await running.log?.waitForExit(deadline: .seconds(5))
        let poster = running.folder.appendingPathComponent(stopped.poster)
        let saved = (try? await backend.screenshot(stopped.recording.device.id, to: poster)) != nil
            && FileManager.default.fileExists(atPath: poster.path)
        let files = try rules(Files.self, "recording_files", ["recording": PhoneRules.field(stopped.recording), "poster": saved])
        try Data(files.manifest.utf8).write(to: running.folder.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(files.eventsJsonl.utf8).write(to: running.folder.appendingPathComponent("events.jsonl"), options: .atomic)
        try Data(files.notesMd.utf8).write(to: running.folder.appendingPathComponent("notes.md"), options: .atomic)
        return files.recording.recording(in: running.folder)
    }

    /// Reads a recording folder written by ``stop(notes:)``.
    public static func load(_ folder: URL) throws -> PhoneRecording {
        let manifest = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        return try PhoneRules.decode(PhoneRecordingWire.self, "recording", "recording_read", ["manifest": PhoneRules.text(manifest)],
                                     what: "the recording manifest").recording(in: folder)
    }

    /// `20261019-174203-1a2b`: sorts by time, unique enough for one Mac (`cmux-phone-core`'s `recording_id`).
    public static let timestampID: @Sendable () -> String = {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let time = [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second].map { $0 ?? 0 }
        let uuid = UUID().uuidString
        return (try? PhoneRules.decode(String.self, "id", "recording_id", ["time": time, "uuid": uuid], what: "the recording id")) ?? uuid
    }

    private func nanos(_ duration: Duration) -> Int64 {
        let (seconds, atto) = duration.components
        return seconds &* 1_000_000_000 &+ atto / 1_000_000_000
    }

    /// One recorder op; `already_recording` and `not_recording` throw their ``PhoneError``.
    private func rules<T: Decodable>(_ type: T.Type, _ op: String, _ fields: [String: Any]) throws -> T {
        do {
            return try PhoneRules.reply(T.self, op, fields, what: "the recorder")
        } catch let refusal as PhoneRules.Refusal {
            throw refusal.kind == "already_recording" ? PhoneError.alreadyRecording : PhoneError.notRecording
        }
    }

    private struct Plan: Decodable {
        let video: String
        let log: String?
    }

    private struct Noted: Decodable {
        let recorder: PhoneRecorderWire?
        let noted: Bool
    }

    private struct Stopped: Decodable {
        let recording: PhoneRecordingWire
        let poster: String
    }

    private struct Files: Decodable {
        let recording: PhoneRecordingWire
        let manifest: String
        let eventsJsonl: String
        let notesMd: String

        enum CodingKeys: String, CodingKey {
            case recording, manifest
            case eventsJsonl = "events_jsonl"
            case notesMd = "notes_md"
        }
    }
}
