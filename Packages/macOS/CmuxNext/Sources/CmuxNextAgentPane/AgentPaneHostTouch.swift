public import AppKit

/// The host's own mark that input went to a page, set before the page gets that input.
///
/// A page says that it was touched only when it runs a request (``AgentPaneModel/userTouched``): that is after it
/// got the input, and after its script ran. Between the two the host would take the page for an untouched one, and
/// an untouched New Tab page can be given to another tab. So the host marks the page at the place that sees the
/// input first: a key-down with the page focused and a mouse-down on the page (``AgentPaneView/judge(_:eventWindow:)``),
/// the start of a scroll over the page (``AgentPaneHostMarks/scrolled(_:in:at:)``), a paste and a file drop that the
/// page's view reports, text of the app's dictation, a key that the app's key router queues for a page that is
/// not ready for typing (the queue gives the text to the view, so the view must stay with its tab), and the text of
/// a held key that the view types into its page itself while the app is not active
/// (``AgentPaneView/typeHeldText(of:appIsActive:)``: a task of the view has that text until the page gets it).
///
/// The mark is never taken back, but for one case: a key that the app's key router then runs as an app action
/// (New Tab, Close Tab, a tab switch) was the app's key, not the page's (``AgentPaneHostMarks/ranAction(for:)``).
///
/// Limits. The host does not see these first: text of the system's dictation, a value that an accessibility client
/// sets, a drop that holds no file. For them the page's own report is the mark, as before. A key that the router
/// takes with no app action (the first key of a leader sequence, a key of a hint layer) leaves its mark: the page
/// then stays with its tab, which costs a page and never moves input.
@MainActor public final class AgentPaneHostTouch {
    /// Input went to the page.
    public private(set) var marked = false
    /// What set the mark first (`key`, `mouse`, `scroll`, `paste`, `drop`, `dictation`, `type-ahead`, `held-key`), for diagnostics.
    public private(set) var by: String?
    /// The app's marks (``AgentPaneHostMarks``); nil (a pane made with no shared objects): a key's mark stays.
    var marks: AgentPaneHostMarks?

    public init() {}

    /// Input of the kind `by` goes to the page now.
    public func mark(_ by: String) {
        guard !marked else { return }
        marked = true
        self.by = by
    }

    /// `event` (a key-down with the page focused, or a mouse-down on the page) goes to the page now. A key-down that
    /// sets the mark is noted, so that the key router can take the mark back for a key that it runs as an action.
    func mark(by event: NSEvent) {
        guard !marked else { return }
        if event.type == .keyDown { marks?.note(event, marked: self) }
        mark(event.type == .keyDown ? "key" : "mouse")
    }

    fileprivate func unmark() {
        marked = false
        by = nil
    }
}

/// The app's one object for the host marks of its pages (``AgentPaneHostTouch``): it knows the key-down that set a
/// mark last, and it finds the page under a scroll. The composition root makes it with the person input ledger
/// (``PersonInputLedger/hostMarks``) and gives it to each agent pane (``AgentPaneShared``) and to the key router.
@MainActor public final class AgentPaneHostMarks {
    private weak var touch: AgentPaneHostTouch?
    private var key: (time: TimeInterval, code: UInt16)?

    public init() {}

    /// The key-down `event` set the mark of `touch`, which was not set before.
    func note(_ event: NSEvent, marked touch: AgentPaneHostTouch) {
        self.touch = touch
        key = (time: event.timestamp, code: event.keyCode)
    }

    /// The key router runs an app action for `event` now (nil: no input is in dispatch). When that key-down set a
    /// page's mark, the mark goes, before the action reads it: the key was the app's. An older key's note goes too:
    /// its key went to the page.
    public func ranAction(for event: NSEvent?) {
        let (noted, marked) = (key, touch)
        key = nil
        touch = nil
        guard let noted, let event, event.type == .keyDown, event.timestamp == noted.time, event.keyCode == noted.code else { return }
        marked?.unmark()
    }

    /// A scroll event in `window` at `point` (window coordinates). The start of a gesture, or a tick of a wheel with
    /// no phases, marks the agent page that shows under it. One hit test for each start, none for the events of a
    /// gesture under way: the app sees each scroll event here.
    public func scrolled(_ event: NSEvent, in window: NSWindow?, at point: CGPoint) {
        guard event.type == .scrollWheel, event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty), let window else { return }
        // A Chromium page draws in a child window over its pane: hit-test the pane's own window.
        let host = window.parent ?? window
        guard let content = host.contentView else { return }
        let place = host.convertPoint(fromScreen: window.convertPoint(toScreen: point))
        var view = content.hitTest(content.superview?.convert(place, from: nil) ?? place)
        while let current = view, !(current is AgentPaneView) { view = current.superview }
        (view as? AgentPaneView)?.model.hostTouch.mark("scroll")
    }
}

extension AgentPaneView {
    /// This view shows a New Tab page that nobody used: no input (the page's report or the host's mark), no draft,
    /// no chat, no shell run, no crash notice. Only such a page can serve another New Tab tab, because nothing of
    /// its tab is in it. The caller checks what the view cannot know (the tab's record and its machine).
    public var isUntouchedNewTab: Bool {
        guard let page = model.newTab, !model.userTouched, !model.remoteChat else { return false }
        return page.draft?.isEmpty != false && model.sessionId == nil && !model.shell.hasRuns && !showsCrashNotice
    }
}
