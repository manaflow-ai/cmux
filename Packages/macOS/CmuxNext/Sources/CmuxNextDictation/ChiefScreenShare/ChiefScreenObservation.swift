public import Foundation

/// What the Chief saw on screen at one moment: the entry the journal writes (`inbox/<ms>.json`,
/// `latest.json`) and the Chief's brain turns into a memory note (optchat-chief `screen_share.rs`).
///
/// The JSON keys are the brain's contract: `at`, `day`, `time`, `app`, `window`, `text`, `frame`.
public struct ChiefScreenObservation: Codable, Sendable, Equatable {
    /// When the frame was taken.
    public var at: Date
    /// The local day, `yyyy-MM-dd`.
    public var day: String
    /// The local time, `HH:mm:ss`.
    public var time: String
    /// The app in front, nil when unknown.
    public var app: String?
    /// The front window's title, nil when it has none.
    public var window: String?
    /// The frame's text; empty when it shows none.
    public var text: String
    /// The frame's JPEG on this Mac (absolute path).
    public var frame: String

    /// - Parameters:
    ///   - at: When the frame was taken.
    ///   - day: The local day.
    ///   - time: The local time.
    ///   - app: The app in front.
    ///   - window: The front window's title.
    ///   - text: The frame's text.
    ///   - frame: The JPEG's absolute path.
    public init(at: Date, day: String, time: String, app: String?, window: String?, text: String, frame: String) {
        self.at = at
        self.day = day
        self.time = time
        self.app = app
        self.window = window
        self.text = text
        self.frame = frame
    }
}
