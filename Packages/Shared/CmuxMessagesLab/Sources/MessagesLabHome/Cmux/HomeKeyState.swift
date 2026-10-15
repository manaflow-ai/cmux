import AppKit

// cmux (cx-4o3vq): the one source of MessagesLab's key-window palette state for Home.
//
// `Fixture.inactive` is process-wide: every Home view draws its rows with it. Before, each pane set it from its own
// window's didBecomeKey / didResignKey and from its own window attach, and `setInactive` redrew only that pane, so the
// state followed whichever pane fired last and the other Home views kept rows of the other palette (hq-8c audit,
// .cmux-scratch/messageslab-upstream/b5742f3-colour-audit.md). Now one app-wide observer decides: the key palette when
// the app is active and its key window hosts a Home view, else the inactive palette, and every Home view draws again
// when it changes. Panes never set it. The display-change handler (PaneHost+Scale.swift) never touches it.

/// The app-wide key-window palette state of every Home view.
final class HomeKeyState {
    static let shared = HomeKeyState()

    /// Every Home window view (weak: a closed tab drops out).
    private let views = NSHashTable<MessagesWindowView>.weakObjects()
    private var observers: [NSObjectProtocol] = []

    /// A Home view is in a window (or moved to another): it draws with the app-wide state from now on.
    func register(_ view: MessagesWindowView) {
        views.add(view)
        start()
        apply()
    }

    private func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        // Every window, not only Home's: a window without Home becoming key ends Home's key palette.
        observers = names.map { nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.apply() } }
    }

    /// The state from the app and its key window; on a change every Home view draws again with it.
    func apply() {
        let all = views.allObjects
        let key = NSApp.isActive ? NSApp.keyWindow : nil
        let inactive = !(key.map { window in all.contains { $0.window === window } } ?? false)
        guard inactive != Fixture.inactive else { return }
        // setInactive sets the state, drops the shared row bitmaps and redraws its own view; the other views
        // redraw the same way (their rows otherwise keep the old palette until something else redraws them).
        guard let first = all.first else { Fixture.inactive = inactive; return }
        first.setInactive(inactive)
        for view in all.dropFirst() {
            view.backgroundColor = Fixture.background
            view.chrome.setNeedsDisplay()
            view.chrome.subviews.forEach { $0.setNeedsDisplay() }
            view.refreshVisibleCells()
        }
    }
}
