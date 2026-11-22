public import AppKit

/// Which events of a person pause an agent's lease on a tab (`user.input`).
/// The app calls the provider only from its own event dispatch
/// (`NSApplication.sendEvent`), which driver input never passes: the WebKit
/// driver calls the web view directly and CDP input stays in Chromium.
public struct ProviderUserInput {
    public init() {}
    /// One per press or gesture: key downs (not repeats), mouse downs, and
    /// the start of a scroll gesture (phase began: scrolling changes what
    /// the agent sees). Never releases, drags, moves or magnify, and never
    /// the app's own synthetic input (`debug.mouse` posts through the same
    /// dispatch; the app classifies each event once in `sendEvent`).
    public static func pausesLease(_ event: NSEvent, synthetic: Bool) -> Bool {
        guard !synthetic else { return false }
        switch event.type {
        case .keyDown: return !event.isARepeat
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        case .scrollWheel: return event.phase == .began
        default: return false
        }
    }

    /// `pausesLease(_:synthetic:)` for an event the app did not post.
    public static func pausesLease(_ event: NSEvent) -> Bool { pausesLease(event, synthetic: false) }
}
