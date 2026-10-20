public import Foundation
import Observation

/// The app's one phone service: device list, input (logged into the running
/// recording), screenshots, recording and feedback. Every entry point (phone
/// tab, palette, `cmux phone`, MCP) calls these methods, so they all behave
/// the same.
@MainActor @Observable
public final class PhoneService {
    public private(set) var devices: [PhoneDevice] = []
    /// The running recording, if any (one at a time per app).
    public private(set) var recording: PhoneRecording?
    /// Bumped after every input, boot or recording change, so phone tabs
    /// refresh their still frame on an event instead of a timer.
    public private(set) var changeCount = 0

    public let backend: any PhoneBackend
    private let recorder: PhoneRecorder
    private let scratch: URL
    /// The App sets this to the Home chat.
    public weak var feedbackSink: (any PhoneFeedbackSink)?

    /// - Parameters:
    ///   - recordings: folder for recordings (build-scoped, from the App).
    ///   - scratch: folder for still frames and ad hoc screenshots.
    public init(backend: any PhoneBackend, recordings: URL, scratch: URL) {
        self.backend = backend
        recorder = PhoneRecorder(backend: backend, root: recordings)
        self.scratch = scratch
    }

    /// For tests: a recorder with injected clocks.
    public init(backend: any PhoneBackend, recorder: PhoneRecorder, scratch: URL) {
        self.backend = backend
        self.recorder = recorder
        self.scratch = scratch
    }

    @discardableResult
    public func reload() async throws -> [PhoneDevice] {
        devices = try await backend.devices()
        return devices
    }

    /// The device for `id` (from the last list; lists again when unknown).
    public func device(_ id: PhoneDeviceID) async throws -> PhoneDevice {
        if let known = devices.first(where: { $0.id == id }) { return known }
        try await reload()
        guard let found = devices.first(where: { $0.id == id }) else { throw PhoneError.unknownDevice(id.description) }
        return found
    }

    /// The device commands use when none is named: the recorded one, else the
    /// first ready simulator, else the first ready phone.
    public func defaultDevice() async throws -> PhoneDevice {
        if let recording { return recording.device }
        if devices.isEmpty { try await reload() }
        let ready = devices.filter(\.state.isReady)
        guard let pick = ready.first(where: { $0.mode == .simulator }) ?? ready.first ?? devices.first(where: { $0.mode == .simulator })
        else { throw PhoneError.unknownDevice("(none)") }
        return pick
    }

    public func capabilities(_ device: PhoneDevice) -> PhoneCapabilities {
        backend.capabilities(for: device)
    }

    public func boot(_ id: PhoneDeviceID) async throws {
        try await backend.boot(id)
        try? await reload()
        changeCount += 1
    }

    public func shutdown(_ id: PhoneDeviceID) async throws {
        try await backend.shutdown(id)
        try? await reload()
        changeCount += 1
    }

    /// Sends `input`, logging it into the running recording first so its
    /// time matches the moment it was asked for.
    public func send(_ input: PhoneInput, to id: PhoneDeviceID) async throws {
        let device = try await device(id)
        guard backend.capabilities(for: device).contains(input.requiredCapability) else {
            throw PhoneError.unsupported(mode: id.mode, what: input.kind)
        }
        await recorder.note(input, on: id)
        try await backend.send(input, to: id)
        changeCount += 1
    }

    /// Saves a PNG of `id`'s screen to `file` (a new scratch file when nil) and returns its path.
    public func screenshot(_ id: PhoneDeviceID, to file: URL? = nil) async throws -> URL {
        let target = file ?? scratch.appendingPathComponent("screenshot-\(UUID().uuidString.prefix(8)).png")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await backend.screenshot(id, to: target)
        return target
    }

    /// The still frame a phone tab shows: one file per device, rewritten.
    public func frame(_ id: PhoneDeviceID) async throws -> URL {
        let safe = id.description.replacingOccurrences(of: ":", with: "-")
        return try await screenshot(id, to: scratch.appendingPathComponent("frame-\(safe).png"))
    }

    @discardableResult
    public func startRecording(_ id: PhoneDeviceID) async throws -> PhoneRecording {
        let device = try await device(id)
        guard backend.capabilities(for: device).contains(.recordVideo) else {
            throw PhoneError.unsupported(mode: id.mode, what: "recording")
        }
        let started = try await recorder.start(device)
        recording = started
        changeCount += 1
        return started
    }

    public func stopRecording(notes: String = "") async throws -> PhoneRecording {
        defer { recording = nil; changeCount += 1 }
        return try await recorder.stop(notes: notes)
    }

    /// Stops the running recording (when one runs) and sends it to the
    /// feedback sink (the Home chat) as one message with the clip attached.
    /// With no sink, returns the clip unsent.
    @discardableResult
    public func sendFeedback(notes: String = "", recording finished: PhoneRecording? = nil) async throws -> PhoneFeedbackClip {
        let done: PhoneRecording
        if let finished { done = finished } else { done = try await stopRecording(notes: notes) }
        let clip = PhoneFeedbackClip.load(done)
        try await feedbackSink?.send(clip)
        return clip
    }
}
