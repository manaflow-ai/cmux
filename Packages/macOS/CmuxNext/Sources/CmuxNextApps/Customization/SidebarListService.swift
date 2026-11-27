import AppKit
import CmuxNextCompat
public import CmuxNextDesign

/// The person's own workspace list (`cmux.sidebar/1`): mounts the installed app named in
/// `sidebar.workspaceListApp` and hands the sidebar its view. Opt-in: with no app named (the
/// default) it mounts nothing and the sidebar draws its built-in list. The built-in list is also the
/// fallback while the chosen app is not installed, hidden or disabled, apps cannot run here (no app
/// host, apps off, safe mode), the list loads, or its script fails or crashes (DESIGN R5;
/// ``SidebarListReplacement``). A fixed save remounts it; scripts run in the daemon's sandboxed app
/// host, and this only mounts and hosts.
@MainActor
public final class SidebarListService: SidebarListReplacement {
    nonisolated static let interface = "cmux.sidebar/1"

    private let client: AppsClient
    private let isPresented: (String) -> Bool
    /// `sidebar.workspaceListApp`: the app id the person chose, or nil for the built-in list; read
    /// inside the observation, so a settings change remounts.
    private let chosenApp: () -> String?
    public var content: (any SidebarCustomContent)? { list }
    private var list: AppSidebarListContent?
    public var onContentChange: (() -> Void)?
    private var mountedKey: String?
    private var appsWatch: Task<Void, Never>?

    public init(client: AppsClient, chosenApp: @escaping () -> String?, isPresented: @escaping (String) -> Bool) {
        self.chosenApp = chosenApp
        self.client = client
        self.isPresented = isPresented
        // task-owner: the service lives as long as the app; one watch of which app draws the list.
        appsWatch = Task { [weak self] in
            // A trigger: the same key remounts after a failed render (a fixed script keeps its version).
            for await key in ObservationStream({ [weak self] in ObservationTrigger(self?.implementationKey()) }) {
                self?.remount(key.value)
            }
        }
    }

    /// The chosen app's `cmux.sidebar/1`, when it can draw here now.
    func implementation() -> (app: String, implementation: AppImplementation)? {
        guard let id = chosenApp() else { return nil }
        if let reason = client.unavailableReason, !reason.daemonUnreachable { return nil }
        guard let app = client.app(id), isPresented(app.id),
              let found = app.manifest.sceneImplementation(interface: Self.interface) else { return nil }
        return (app.id, found)
    }

    /// `app#implementation@version`: a new version remounts (a reloaded script).
    private func implementationKey() -> String? {
        guard let (app, found) = implementation() else { return nil }
        return "\(app)#\(found.id)@\(client.app(app)?.manifest.version ?? "")"
    }

    /// Ends the list's mount and the watch (the window's sidebar went away or was made again).
    public func release() {
        appsWatch?.cancel()
        appsWatch = nil
        list?.release()
        list = nil
        mountedKey = nil
    }

    private func remount(_ key: String?) {
        // Only a failed render remounts with the same key; a disconnected mount reconnects itself.
        guard key != mountedKey || list?.hasFailed == true else { return }
        mountedKey = key
        list?.release()
        list = nil
        if key != nil, let (app, found) = implementation() {
            let mount = client.mount(app, implementation: found, surface: "sidebarList")
            let list = AppSidebarListContent(scene: AppHoverCardContent(mount: mount, client: client))
            list.onChange = { [weak self] in self?.onContentChange?() }
            self.list = list
        }
        onContentChange?()
    }
}

/// One mounted workspace list: the scene in a scroll view the list's height, ready and failed as its
/// mount is.
@MainActor
final class AppSidebarListContent: SidebarCustomContent {
    private let scene: AppHoverCardContent
    private let scroll: AppSceneScrollView
    var view: NSView { scroll }
    var onChange: (() -> Void)? {
        didSet { scene.onChange = { [weak self] in self?.scroll.contentChanged(); self?.onChange?() } }
    }

    init(scene: AppHoverCardContent) {
        self.scene = scene
        scroll = AppSceneScrollView(document: scene.view)
        // A height change with no new scene or status (an image that loaded) resizes the document too.
        (scene.view as? AppSceneHostingView)?.onContentSizeChange = { [weak scroll] in scroll?.contentChanged() }
    }

    /// The script failed to load or render (not a disconnect, which reconnects by itself).
    var hasFailed: Bool { scene.hasFailed }
    var isReady: Bool { scene.isReady }
    var errorText: String? { scene.errorText }
    func preferredHeight(width: CGFloat) -> CGFloat { scene.preferredHeight(width: width) }
    func release() { scene.release() }
}

/// A scene taller than its frame scrolls, with the sidebar's thin scroller.
final class AppSceneScrollView: NSScrollView {
    private let document: NSView

    init(document: NSView) {
        self.document = document
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        automaticallyAdjustsContentInsets = false
        contentView.drawsBackground = false
        SystemScrollers.followThin(self)
        documentView = document
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The scene's rows changed: its height may have.
    func contentChanged() { needsLayout = true }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        let height = max(contentView.bounds.height, (document as? AppSceneHostingView)?.preferredHeight(width: width) ?? document.fittingSize.height)
        let size = NSSize(width: width, height: height)
        if document.frame.size != size { document.setFrameSize(size) }
    }
}
