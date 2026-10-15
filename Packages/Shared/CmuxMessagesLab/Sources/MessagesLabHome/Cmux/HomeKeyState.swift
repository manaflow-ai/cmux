import AppKit

// cmux (cx-4o3vq): the one source of MessagesLab's key-window palette state for Home.
//
// `Fixture.inactive` is process-wide: every Home view draws its rows with it. Before, each pane set it from its own
// window's didBecomeKey / didResignKey and from its own window attach, and `setInactive` redrew only that pane, so the
// state followed whichever pane fired last and the other Home views kept rows of the other palette (hq-8c audit,
// .cmux-scratch/messageslab-upstream/b5742f3-colour-audit.md). Now one app-wide observer decides: the key palette when
// the app is active and its key window hosts a Home view, else the inactive palette, and every Home view draws again
// when it changes. Panes never set it. The display-change handler (PaneHost+Scale.swift) never touches it.

/// The app-wide key-window palette state of every Home view. Main thread only: its callers are AppKit view and
/// window callbacks and `.main` queue observers (the package builds in Swift 5 mode, so this is not annotated).
final class HomeKeyState {
    static let shared = HomeKeyState()

    /// Every Home pane controller (weak: a closed tab drops out).
    private let panes = NSHashTable<ChatController>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var pending = false

    /// A Home pane is in a window (or moved to another): it draws with the app-wide state from now on.
    func register(_ pane: ChatController) {
        panes.add(pane)
        start()
        setNeedsApply()  // a new window attaches before it becomes key: one apply after both
    }

    private func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        // Every window, not only Home's: a window without Home becoming key ends Home's key palette.
        observers = names.map { nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.setNeedsApply() } }
    }

    /// Once per main run loop turn: a switch between two windows posts a resign and a become, and between them the
    /// state would be inactive for one call (every Home view's rows drawn twice).
    func setNeedsApply() {
        guard !pending else { return }
        pending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.pending = false
            self?.apply()
        }
    }

    /// The state from the app and its key window; on a change every Home view draws again with it.
    func apply() {
        let all = panes.allObjects
        // No registered pane (noFocus runs with --active / --inactive never register): the state is not ours to set.
        guard !all.isEmpty else { return }
        let views = all.compactMap(\.demo)
        let key = NSApp.isActive ? NSApp.keyWindow : nil
        // A shown Home only (its host view, the NSView in the window): a workspace or tab that is not selected keeps
        // its hidden Home in the window.
        var hostsHome = false
        if let key {
            for pane in all where pane.demo != nil && pane.host.window === key && !pane.host.isHiddenOrHasHiddenAncestor { hostsHome = true }
        }
        let inactive = !hostsHome
        guard inactive != Fixture.inactive else { return }
        // setInactive sets the state, drops the shared row bitmaps and redraws its own view; the other views
        // redraw the same way (their rows otherwise keep the old palette until something else redraws them).
        guard let first = views.first else { Fixture.inactive = inactive; return }  // panes without a window view yet
        first.setInactive(inactive)
        for view in views.dropFirst() {
            view.backgroundColor = Fixture.background
            view.chrome.setNeedsDisplay()
            view.chrome.subviews.forEach { $0.setNeedsDisplay() }
            view.refreshVisibleCells()
        }
        // The header's tint is the palette's background (MessagesLabHomeView.applyTheme sets it the same way).
        for pane in all { pane.host.headerBackdrop.setTint(Fixture.background) }
    }
}
