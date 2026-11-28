import Foundation

/// A recording as `cmux-phone-core` reads and writes it (`started_at`, the device's `state.kind`); hand copy of its
/// `Recording`. The folder stays on the Swift side; dates are ISO 8601, as the manifest has them.
struct PhoneRecordingWire: Codable {
    var id: String
    var device: PhoneDeviceReply
    var startedAt: String
    var duration: Double
    var video: String
    var log: String?
    var poster: String?
    var events: [PhoneRecordingEvent]
    var notes: String

    enum CodingKeys: String, CodingKey {
        case id, device, duration, video, log, poster, events, notes
        case startedAt = "started_at"
    }

    init(_ recording: PhoneRecording) {
        id = recording.id
        device = PhoneDeviceReply(recording.device)
        startedAt = recording.startedAt.formatted(.iso8601)
        duration = recording.duration
        video = recording.video
        log = recording.log
        poster = recording.poster
        events = recording.events
        notes = recording.notes
    }

    func recording(in folder: URL) -> PhoneRecording {
        var recording = PhoneRecording(id: id, device: device.device, startedAt: (try? Date(startedAt, strategy: .iso8601)) ?? Date(timeIntervalSince1970: 0),
                                       video: video, log: log, folder: folder)
        recording.duration = duration
        recording.poster = poster
        recording.events = events
        recording.notes = notes
        return recording
    }
}

/// The recorder's state between `cmux-phone-core` calls: the running recording and the uptime it started at; hand
/// copy of its `Recorder`.
struct PhoneRecorderWire: Codable {
    var recording: PhoneRecordingWire
    var startedNanos: Int64

    enum CodingKeys: String, CodingKey {
        case recording
        case startedNanos = "started_nanos"
    }
}
