import AppKit
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextWakeups

/// A closed agent page leaves the view tree at once (cheap); its teardown
/// (WKWebView stop and unload, bridge and observer removal) runs at a quiet
/// moment after the close, so a Cmd-W frame never pays for it (R81). A closed chat of this Mac
/// is kept whole for 30 s first (``ClosedPageKeeper``, at most two pages): Reopen Closed takes it
/// back loaded and drawn. A kept page waits parked in the window it closed in, off screen
/// (``PageOffscreenParking``), so it stays drawn: a Chromium page detached from its window is
/// hidden and drew nothing until the reopen showed it again, and under load the reopened split
/// stood blank for 50 to 100 ms before its content came (a second phase in its motion).
@MainActor
public final class AgentPageRetirer {
    public static let delay: Duration = .milliseconds(500)
    private var retiring: [AgentPaneView] = []
    /// One parking per window a kept page closed in; an empty one goes at the next retire or teardown.
    private var parkings: [PageOffscreenParking] = []
    private let timer = DemandTimer(owner: "AgentPageRetirer")
    /// The app's bench spans around the detach and the teardown (`agentPane.detach`, `agentPane.close`).
    private let measure: @MainActor (String, () -> Void) -> Void
    private lazy var kept = ClosedPageKeeper<AgentPaneView>(limit: 2, keepFor: .seconds(30), owner: "AgentPageRetirer.keep") { [weak self] in
        self?.teardown($0)
    }

    public init(measure: @escaping @MainActor (String, () -> Void) -> Void = { _, body in body() }) {
        self.measure = measure
    }

    /// The kept pages, under keys no tab has: a quit asks them too (``AgentPaneRelaunchWake/collect(held:pages:live:limit:)``),
    /// so prompts they hold go into their chats' drafts.
    public var keptPages: [(key: String, view: AgentPaneView)] { kept.pages.map { ("kept:\($0.session)", $0.page) } }

    /// The kept page of closed chat `session`, taken back.
    public func takeKept(_ session: String) -> AgentPaneView? { kept.take(session) }

    /// Retires `view`; a chat page of this Mac showing `session` is kept first.
    public func retire(_ view: AgentPaneView, keeping session: String? = nil) {
        // A closed New Tab page drops the chat a chip pick started behind it; the page stays alive
        // until the teardown below, long enough to send the discard.
        view.topBar.discardUnsentChat()
        pruneParkings()
        // A page that is dictating is not kept: its microphone session belongs to the closed tab.
        if let session, view.dictation.phase.isStartable, !LowPowerMode.system.isEnabled {
            view.quietForKeep()
            measure("agentPane.detach") { park(view) }
            if kept.keep(view, for: session) { return }
        }
        if view.superview != nil, !(view.superview is PageOffscreenParking) {
            measure("agentPane.detach") { view.removeFromSuperview() }
        }
        teardown(view)
    }

    /// Moves `view` out of its pane into its window's parking (one reparent, as the detach was), still
    /// in the window, so its page keeps its drawn frame; a view in no window only leaves its superview.
    /// Only a Chromium page is parked: a parked page shows again through the moved-page path
    /// (`AgentTabContent.coverMove`), which covers a WebKit page with a New Tab frame, never a chat's own.
    /// A WebKit page leaves the tree, as every kept page did before the parking.
    private func park(_ view: AgentPaneView) {
        guard view.pageDrawsOverCovers, let window = view.window, let content = window.contentView else { return view.removeFromSuperview() }
        // A parked page never holds the keyboard.
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { window.makeFirstResponder(nil) }
        let parking = parkings.first { $0.superview === content } ?? {
            let made = PageOffscreenParking()
            made.autoresizingMask = []
            content.addSubview(made, positioned: .below, relativeTo: nil)
            parkings.append(made)
            return made
        }()
        let size = view.frame.size
        parking.frame = PageOffscreenParking.frame(in: content.bounds, size: CGSize(width: max(parking.frame.width, size.width), height: max(parking.frame.height, size.height)))
        view.autoresizingMask = []
        parking.addSubview(view)
        view.frame = CGRect(origin: .zero, size: size)
        // The pane hid the page when it let it go (`PaneContentView.retire`): hidden, Chromium drops its frame.
        view.isHidden = false
        PageWebView.syncChromiumVisibility(in: view)
    }

    /// Removes the parkings no kept page waits in any more (taken back into a pane, or torn down).
    private func pruneParkings() {
        parkings.removeAll { parking in
            guard parking.subviews.isEmpty || parking.superview == nil else { return false }
            parking.removeFromSuperview()
            return true
        }
    }

    private func teardown(_ view: AgentPaneView) {
        // A kept page leaves its parking (and the window) when its keep ends.
        if view.superview is PageOffscreenParking { view.removeFromSuperview() }
        if view.superview == nil { pruneParkings() }
        retiring.append(view)
        timer.schedule(after: Self.delay) { @MainActor [weak self] in self?.flush() }
    }

    private func flush() {
        let views = retiring
        retiring.removeAll()
        for view in views { view.releaseHeldPrompts { [measure] retired in measure("agentPane.close") { retired.close() } } }
    }
}

extension AgentPaneView {
    /// What a close ends that a kept closed page must not keep doing: its shell runs (commands that
    /// change files) and read aloud. Prompts it holds for a folder trust answer stay in it as they
    /// were, so a reopen shows them unchanged; its teardown or a quit (``AgentPageRetirer/keptPages``)
    /// puts them into their chats' drafts, as a close does. The page stays loaded and drawn.
    func quietForKeep() {
        model.shell.terminateAll()
        model.readAloud?.stop(owner: model)
    }
}
