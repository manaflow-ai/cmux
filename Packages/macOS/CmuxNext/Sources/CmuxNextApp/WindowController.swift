import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import Observation

/// One window: sidebar, titlebar, and the content of the workspace it shows.
/// Which workspace that is, plus frame and sidebar width, persist in the
/// daemon's personal projection through `WindowManager`.
final class WindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState
    let sidebar: SidebarBridge
    let root: WindowRootView
    private(set) var content: WorkspaceContentController?
    unowned let services: AppServices
    private var workspaceObservation: Task<Void, Never>?
    private var titleObservation: Task<Void, Never>?

    init(state: WindowState, services: AppServices, frame: NSRect?) {
        self.state = state
        self.services = services
        sidebar = SidebarBridge(services: services, state: state)
        root = WindowRootView(sidebar: sidebar.container)
        let window = ShellWindow(
            contentRect: frame ?? NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.registry = services.registry
        window.title = Strings.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = Palette.windowBackground
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = root
        // contentRect grows by the titlebar; restore the saved frame exactly.
        if let frame { window.setFrame(frame, display: false) } else { window.center() }
        super.init(window: window)
        window.delegate = self
        observeWorkspace()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func teardown() {
        workspaceObservation?.cancel()
        titleObservation?.cancel()
        content?.teardown()
        content = nil
        sidebar.teardown()
    }

    // MARK: Workspace

    private func observeWorkspace() {
        let store = services.daemon.store
        let state = state
        workspaceObservation = Task { [weak self] in
            for await ids in Observations({ (state.workspaceID, store.workspaces.map(\.id)) }) {
                self?.showWorkspace(requested: ids.0, available: ids.1)
            }
        }
    }

    /// Shows the requested workspace, or the first one when it is gone.
    private func showWorkspace(requested: String?, available: [String]) {
        let store = services.daemon.store
        let id = requested.flatMap { available.contains($0) ? $0 : nil } ?? (store.isLoaded ? available.first : nil)
        guard let id, let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
        if state.workspaceID != id { state.workspaceID = id }
        guard content?.workspace !== workspace else { return }
        content?.teardown()
        let controller = WorkspaceContentController(workspace: workspace, services: services, state: state)
        content = controller
        root.show(controller.layoutView)
        titleObservation?.cancel()
        titleObservation = Task { [weak self] in
            for await title in Observations({ workspace.displayName }) { self?.root.titlebar.title = title }
        }
        controller.focusCurrentPane()
        services.windows.stateDidChange(state)
    }

    var focusedPane: PaneController? { content?.focusedPane }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        services.windows.didActivate(self)
    }

    func windowDidMove(_ notification: Notification) { services.windows.stateDidChange(state) }
    func windowDidEndLiveResize(_ notification: Notification) { services.windows.stateDidChange(state) }

    func windowWillClose(_ notification: Notification) {
        services.windows.windowWillClose(self)
    }
}

/// Routes key equivalents through the action registry before the terminal
/// sees them, and reports first-responder changes to the owning pane so
/// layout focus follows the keyboard.
final class ShellWindow: NSWindow {
    weak var registry: ActionRegistry?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if registry?.performShortcut(for: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, var view = responder as? NSView {
            while let parent = view.superview, !(view is PaneContentView) { view = parent }
            (view as? PaneContentView)?.onFocus?()
        }
        return accepted
    }
}
