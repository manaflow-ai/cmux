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
public struct BrowserReplTabOwnership: Sendable, Equatable {
    /// The attached session that created the tab, if any.
    public private(set) var creatorSessionID: String?
    private var attachedSessionIDs: Set<String> = []
    private var handledEvents: [String: Set<BrowserReplTabEvent>] = [:]

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
        if creatorSessionID == sessionID { creatorSessionID = nil }
    }

    /// Replaces the events `sessionID` handles on this tab. Ignored for a
    /// session that is not attached.
    public mutating func setHandledEvents(_ events: Set<BrowserReplTabEvent>, for sessionID: String) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        handledEvents[sessionID] = events.isEmpty ? nil : events
    }

    /// Whether an attached session created the tab, so the session's own
    /// policies (permission answers from `session.configure`, no
    /// insecure-HTTP prompt) apply.
    public var isSessionOwned: Bool {
        guard let creatorSessionID else { return false }
        return attachedSessionIDs.contains(creatorSessionID)
    }

    /// Whether `event` goes to the attached sessions instead of the user's UI.
    public func routesToSessions(_ event: BrowserReplTabEvent) -> Bool {
        isSessionOwned || handledEvents.values.contains { $0.contains(event) }
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
