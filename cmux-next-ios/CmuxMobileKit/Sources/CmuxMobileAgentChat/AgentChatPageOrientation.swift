import Foundation

/// The agent chats pushed on a NavigationStack (Home's, the Feed's) that are on
/// screen. They turn with the phone like a workspace's chat tab page (Leo,
/// 2026-11-23: "why do we not have a horizontal mode?"); before this only the
/// tab page reported itself, so the chat opened from Home stayed portrait
/// (LandscapeUITests testE, step 836d3f58: "the agent chat turns landscape:
/// 402x874"). The app delegate wires `onChange` to `ScreenSharingOrientation`.
@MainActor
public final class AgentChatPageOrientation {
    public static let shared = AgentChatPageOrientation()

    private var shown: Set<UUID> = []

    /// Called when the first chat comes on screen or the last one leaves.
    public var onChange: (@MainActor (Bool) -> Void)?

    public var isShowing: Bool { !shown.isEmpty }

    public init() {}

    public func page(_ id: UUID, shows: Bool) {
        let was = isShowing
        if shows { shown.insert(id) } else { shown.remove(id) }
        if was != isShowing { onChange?(isShowing) }
    }
}
