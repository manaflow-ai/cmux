import Foundation

/// What the media hub button shows: how many tabs have media and whether
/// one plays (the button is then drawn active).
public nonisolated struct BrowserToolbarMedia: Hashable, Sendable {
    public var sessions: Int
    public var isPlaying: Bool

    public init(sessions: Int = 0, isPlaying: Bool = false) {
        self.sessions = sessions
        self.isPlaying = isPlaying
    }
}
