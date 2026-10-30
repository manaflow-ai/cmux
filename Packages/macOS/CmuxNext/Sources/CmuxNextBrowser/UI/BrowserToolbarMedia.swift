import Foundation

/// What the media hub button knows: how many tabs have media and whether one plays. The
/// button is not drawn on while a tab plays: Chrome's media button is pressed only while its
/// dialog is open (u2426).
public nonisolated struct BrowserToolbarMedia: Hashable, Sendable {
    public var sessions: Int
    public var isPlaying: Bool

    public init(sessions: Int = 0, isPlaying: Bool = false) {
        self.sessions = sessions
        self.isPlaying = isPlaying
    }
}
