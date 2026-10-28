public import Foundation

/// A finished (or running) recording: one folder with the screen video, the
/// inputs sent through cmux, the device log and the person's notes.
/// `manifest.json` in the folder is this value.
public struct PhoneRecording: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var device: PhoneDevice
    public var startedAt: Date
    /// Seconds; zero while running.
    public var duration: Double
    /// File names inside ``folder``.
    public var video: String
    public var log: String?
    public var poster: String?
    public var events: [PhoneRecordingEvent]
    public var notes: String
    /// The folder on this Mac (not encoded; the manifest sits inside it).
    public var folder: URL

    public init(id: String, device: PhoneDevice, startedAt: Date, video: String, log: String?, folder: URL) {
        self.id = id
        self.device = device
        self.startedAt = startedAt
        duration = 0
        self.video = video
        self.log = log
        poster = nil
        events = []
        notes = ""
        self.folder = folder
    }

    public var videoURL: URL { folder.appendingPathComponent(video) }
    public var logURL: URL? { log.map { folder.appendingPathComponent($0) } }
    public var posterURL: URL? { poster.map { folder.appendingPathComponent($0) } }

    private enum CodingKeys: String, CodingKey {
        case id, device, startedAt, duration, video, log, poster, events, notes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        device = try values.decode(PhoneDevice.self, forKey: .device)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        duration = try values.decode(Double.self, forKey: .duration)
        video = try values.decode(String.self, forKey: .video)
        log = try values.decodeIfPresent(String.self, forKey: .log)
        poster = try values.decodeIfPresent(String.self, forKey: .poster)
        events = try values.decode([PhoneRecordingEvent].self, forKey: .events)
        notes = try values.decode(String.self, forKey: .notes)
        // decode-trap-allow: a dictionary lookup (nil when absent), not an index into input bytes
        folder = (CodingUserInfoKey.phoneRecordingFolder.flatMap { decoder.userInfo[$0] } as? URL) ?? URL(fileURLWithPath: "/")
        // A manifest is a file on disk: a time or point no recording can have is refused here, at the boundary,
        // so the feedback summary's whole-number conversions (PhoneFeedbackClip) only ever see values that fit.
        guard Self.isPlausible(duration), events.allSatisfy(Self.isPlausibleEvent) else {
            throw DecodingError.dataCorruptedError(forKey: .events, in: values,
                                                   debugDescription: "a time or point past \(Self.maxMagnitude)")
        }
    }

    /// The largest time (seconds) or coordinate (points) a manifest may hold: far past any recording or screen,
    /// and small enough that `Int((value * 10).rounded())` is exact.
    static let maxMagnitude = 1e9

    /// False for NaN and the infinities too (`abs` of either is never `<=` a finite bound).
    static func isPlausible(_ value: Double) -> Bool {
        abs(value) <= maxMagnitude
    }

    private static func isPlausibleEvent(_ event: PhoneRecordingEvent) -> Bool {
        isPlausible(event.at) && [event.point, event.to].allSatisfy { $0?.isPlausible ?? true }
    }
}

extension CodingUserInfoKey {
    /// The folder a decoded ``PhoneRecording`` was read from. Optional because
    /// `CodingUserInfoKey.init?(rawValue:)` is failable (it never fails for this literal).
    public static let phoneRecordingFolder = CodingUserInfoKey(rawValue: "phoneRecordingFolder")
}
