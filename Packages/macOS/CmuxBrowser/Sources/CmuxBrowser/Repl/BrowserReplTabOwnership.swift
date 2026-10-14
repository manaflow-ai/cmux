/// A tab event a REPL session can take over from cmux's own UI.
public enum BrowserReplTabEvent: String, CaseIterable, Sendable {
    /// JavaScript `alert`, `confirm`, `prompt` and `beforeunload` dialogs.
    case dialog
    /// The open panel of an `<input type="file">`.
    case fileChooser = "filechooser"
    /// A download: kept in the temporary directory and reported to the session.
    case download
}

/// Decides, for one browser tab that REPL sessions drive, whether the
/// sessions or the user's normal UI answer its dialogs, file choosers,
/// downloads, permission requests and insecure-HTTP prompts.
///
/// A session's behaviors apply to a tab it created (`tabs.open`, and popups
/// of such a tab) while that session stays attached. Any other tab is the
/// user's (one the user opened, or one a finished run kept): it keeps cmux's
/// normal UI, except for an event an attached session registered a handler
/// for on that page (`tab.handleEvents`, sent for `page.on("dialog")`,
/// `waitForEvent("download")` and the like); only that event goes to the
/// sessions.
///
/// A dialog or file chooser the page opens while it handles a session's own
/// input (a click, key, drag or navigation the session sent) goes to that
/// session too, also in a user's tab: the agent caused it, so cmux's UI
/// must neither come up in front of the user nor leave the agent waiting
/// for an answer only the user can give. Downloads keep the user's location.
///
/// A routed event goes to one session (``recipient(for:)``), and only that
/// session may answer it: a second session driving the same tab never sees
/// or answers a dialog, file chooser or download routed to another.
public struct BrowserReplTabOwnership: Sendable, Equatable {
    /// The attached session that created the tab, if any.
    public private(set) var creatorSessionID: String?
    private var attachedSessionIDs: Set<String> = []
    private var handledEvents: [String: Set<BrowserReplTabEvent>] = [:]
    /// Sessions with a handler, in the order they registered one.
    private var handlerOrder: [String] = []
    /// Sessions whose input the page is handling, latest last.
    private var inputSessionIDs: [String] = []

    public init() {}

    /// Records that `sessionID` drives the tab.
    public mutating func attach(sessionID: String) {
        attachedSessionIDs.insert(sessionID)
    }

    /// Records that `sessionID` created the tab. The first creator wins.
    public mutating func markCreated(by sessionID: String) {
        attachedSessionIDs.insert(sessionID)
        if creatorSessionID == nil { creatorSessionID = sessionID }
    }

    /// Records that `sessionID` left the tab. When it created the tab, the
    /// tab becomes the user's for the sessions that remain.
    public mutating func detach(sessionID: String) {
        attachedSessionIDs.remove(sessionID)
        handledEvents.removeValue(forKey: sessionID)
        handlerOrder.removeAll { $0 == sessionID }
        inputSessionIDs.removeAll { $0 == sessionID }
        if creatorSessionID == sessionID { creatorSessionID = nil }
    }

    /// Records that the page is handling input `sessionID` sent; dialogs and
    /// file choosers it opens until ``endInput(sessionID:)`` go to that
    /// session. Ignored for a session that is not attached.
    public mutating func beginInput(sessionID: String) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        inputSessionIDs.append(sessionID)
    }

    /// The session whose input the page is handling now, if any.
    public var inputSessionID: String? {
        inputSessionIDs.last
    }

    /// Ends one ``beginInput(sessionID:)``.
    public mutating func endInput(sessionID: String) {
        if let index = inputSessionIDs.lastIndex(of: sessionID) {
            inputSessionIDs.remove(at: index)
        }
    }

    /// Replaces the events `sessionID` handles on this tab. Ignored for a
    /// session that is not attached.
    public mutating func setHandledEvents(_ events: Set<BrowserReplTabEvent>, for sessionID: String) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        handledEvents[sessionID] = events.isEmpty ? nil : events
        if events.isEmpty {
            handlerOrder.removeAll { $0 == sessionID }
        } else if !handlerOrder.contains(sessionID) {
            handlerOrder.append(sessionID)
        }
    }

    /// Whether an attached session created the tab, so the session's own
    /// policies (permission answers from `session.configure`, no
    /// insecure-HTTP prompt) apply.
    public var isSessionOwned: Bool {
        guard let creatorSessionID else { return false }
        return attachedSessionIDs.contains(creatorSessionID)
    }

    /// Whether `event` goes to a session instead of the user's UI.
    public func routesToSessions(_ event: BrowserReplTabEvent) -> Bool {
        recipient(for: event) != nil
    }

    /// The one session `event` goes to, or `nil` when it keeps the user's
    /// UI: a session with a handler for it (the creator's first, then the
    /// session that registered its handler first), else the attached
    /// creator of a tab a session created, else, for a dialog or file
    /// chooser, the session whose input the page is handling.
    public func recipient(for event: BrowserReplTabEvent) -> String? {
        let creator = isSessionOwned ? creatorSessionID : nil
        if let creator, handledEvents[creator]?.contains(event) == true { return creator }
        if let handler = handlerOrder.first(where: { handledEvents[$0]?.contains(event) == true }) {
            return handler
        }
        if let creator { return creator }
        guard event != .download else { return nil }
        return inputSessionIDs.last
    }

    /// Parses `tab.handleEvents` names.
    /// - Returns: `nil` when a name is not a ``BrowserReplTabEvent``.
    public static func events(named names: [String]) -> Set<BrowserReplTabEvent>? {
        var events = Set<BrowserReplTabEvent>()
        for name in names {
            guard let event = BrowserReplTabEvent(rawValue: name) else { return nil }
            events.insert(event)
        }
        return events
    }
}
