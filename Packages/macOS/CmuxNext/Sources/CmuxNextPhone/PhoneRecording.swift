public import Foundation

/// A finished (or running) recording: one folder with the screen video, the
/// inputs sent through cmux, the device log and the person's notes.
/// `manifest.json` in the folder is this value (`cmux-phone-core` writes and reads it).
public struct PhoneRecording: Sendable, Hashable, Identifiable {
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
    /// The folder on this Mac (not in the manifest, which sits inside it).
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
}
