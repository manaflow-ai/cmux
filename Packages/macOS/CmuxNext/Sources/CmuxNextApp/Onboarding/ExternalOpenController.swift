import AppKit
import CmuxNextActions
import CmuxNextOnboarding

/// Opens what macOS hands cmux as the default browser, the `ssh:` and
/// `x-man-page:` handler, a file's opener, Handoff or the Finder service: a tab in
/// the current window's focused pane, per `ExternalOpenRouter`. A link in
/// this build's scheme (`cmux://tab/…`) runs `link.open`, the one path every
/// link takes. Requests that arrive before a window has content (a cold
/// launch by a link) wait and run when the first window shows its workspace.
@MainActor
final class ExternalOpenController {
    unowned let services: AppServices
    let router: ExternalOpenRouter
    private(set) var pending: [ExternalOpenRoute] = []

    init(services: AppServices) {
        self.services = services
        // Cloud auth's own matcher, so every callback form it accepts
        // (host or path) reaches sign-in, never `link.open`.
        let auth = services.cloud.auth
        router = ExternalOpenRouter(linkScheme: services.linkScheme, isAuthCallback: { auth.isCallback($0) })
    }

    /// Returns false for a URL cmux does not open (the caller refuses it).
    @discardableResult
    func open(_ url: URL) -> Bool {
        let route = router.route(url)
        guard route != .unsupported else { return false }
        perform(route)
        return true
    }

    /// A web link from inside cmux (a feed item): never a file or a command.
    @discardableResult
    func openWebLink(_ url: URL) -> Bool {
        let route = router.routeWebLink(url)
        guard route != .unsupported else { return false }
        perform(route)
        return true
    }

    /// A web page continued from another device (Handoff). False for any
    /// other activity (macOS then reports it could not continue).
    func continueActivity(type: String, webpageURL: URL?) -> Bool {
        let route = router.route(continuing: type, webpageURL: webpageURL)
        guard route != .unsupported else { return false }
        perform(route)
        return true
    }

    /// Finder service "New cmux Tab Here" with the selected paths.
    func newTabHere(_ paths: [String]) {
        for path in paths { perform(router.newTabHere(path)) }
    }

    /// Workspace services: a new workspace (in the current window, or a new
    /// one) whose terminal starts in the folder.
    func newWorkspace(at path: String, newWindow: Bool) {
        guard case .terminal(let cwd, _) = router.newTabHere(path), case let windows = services.windows else { return }
        let target = newWindow ? UUID().uuidString.lowercased() : windows.targetWindow(preferring: windows.active?.state.id)
        let logger = services.daemon.logger
        Task {
            do {
                _ = try await windows.createWorkspace(WorkspaceSpawn(opening: cwd), into: target)
            } catch {
                logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
        if !services.environment.noActivate { NSApp.activate() }
    }

    func perform(_ route: ExternalOpenRoute) {
        let windows = services.windows
        guard let controller = windows.active else {
            pending.append(route)
            if windows.restored, windows.controllers.isEmpty { windows.reopenOrCreateWindow() }
            return
        }
        // The user opened it from another app: a window on a top page (Home)
        // shows a workspace so the tab shows, as a shown internal page does.
        // Without this the open waited until the user left Home.
        controller.leaveTopPage()
        if controller.focusedPane == nil, !controller.showOpenableWorkspace() { createWorkspaceForPending(in: controller) }
        guard let pane = controller.focusedPane else { return pending.append(route) }
        if case .deepLink(let url) = route {
            // The user clicked it in another app: their run, which brings
            // cmux forward. link.open refuses what it cannot open with a reason.
            services.registry.perform("link.open", invocation: ActionInvocation(arguments: ["url": .string(url.absoluteString)]))
        } else {
            deliver(route, to: pane)
            windows.bringToFront(controller)
        }
        if !services.environment.noActivate { NSApp.activate() }
    }

    /// A workspace being created to hold what opens while a window lists
    /// only Home; its content runs the queue (`flush`).
    private var creatingWorkspace = false

    private func createWorkspaceForPending(in controller: WindowController) {
        guard !creatingWorkspace, case let windows = services.windows else { return }
        creatingWorkspace = true
        let target = windows.targetWindow(preferring: controller.state.id)
        let logger = services.daemon.logger
        Task { [weak self] in
            do {
                _ = try await windows.createWorkspace(WorkspaceSpawn(), into: target)
            } catch {
                logger.error("create workspace for an opened file failed: \(String(describing: error), privacy: .public)")
            }
            self?.creatingWorkspace = false
        }
    }

    /// A window installed its content: run what waited for one.
    func flush() {
        guard !pending.isEmpty, services.windows.active?.focusedPane != nil else { return }
        let routes = pending
        pending = []
        routes.forEach(perform)
    }

    private func deliver(_ route: ExternalOpenRoute, to pane: PaneController) {
        switch route {
        case .browserTab(let url): pane.newBrowserTab(url: url)
        case .terminal(let cwd, let command): pane.newTerminalTab(cwd: cwd, typing: command.map { $0 + "\n" })
        // The one file path every opener takes (Open File..., `file.open`); a refusal shows its reason.
        case .file(let url): services.viewers.openFile(url, in: pane, markdown: false)
        case .deepLink, .unsupported: return
        }
    }
}

/// Where `AppDelegate` sends a URL macOS hands cmux: the sign-in callback
/// goes to Cloud auth first (`<scheme>://auth-callback` and the path forms
/// auth accepts), so it never reaches `link.open`; everything else goes to
/// `ExternalOpenController`, which refuses what it does not open.
enum OpenedURLRouting {
    enum Destination: Equatable {
        /// Cloud auth's `handleCallback`.
        case auth
        /// `ExternalOpenController` opened it (a tab, or `link.open`).
        case opened
        /// Nothing cmux opens.
        case ignored
    }

    static func route(_ url: URL, isAuthCallback: (URL) -> Bool, open: (URL) -> Bool) -> Destination {
        if isAuthCallback(url) { return .auth }
        return open(url) ? .opened : .ignored
    }
}

/// The Finder services (`NSServices` in Info.plist): New cmux Tab Here,
/// New cmux Workspace Here, New cmux Window Here. AppKit calls these with
/// the selected folders or files (a file opens in its folder).
@MainActor
final class CmuxServicesProvider: NSObject {
    private let open: ExternalOpenController

    init(open: ExternalOpenController) {
        self.open = open
    }

    @objc(newTabHere:userData:error:) func newTabHere(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open.newTabHere(Self.paths(pasteboard))
    }

    @objc(openTab:userData:error:) func openTab(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for path in Self.paths(pasteboard) { open.newWorkspace(at: path, newWindow: false) }
    }

    @objc(openWindow:userData:error:) func openWindow(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for path in Self.paths(pasteboard) { open.newWorkspace(at: path, newWindow: true) }
    }

    /// File URLs, legacy filename lists, or absolute paths as plain text.
    static func paths(_ pasteboard: NSPasteboard) -> [String] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        if let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !names.isEmpty {
            return names
        }
        return (pasteboard.string(forType: .string) ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("/") }
    }
}

extension WindowController {
    /// Shows this window's most recently used workspace that is not Home,
    /// for something opened from another app while Home is shown. False when
    /// the window lists no other workspace. A workspace whose content is not
    /// installed yet runs the queue when it is (`ExternalOpenController.flush`).
    func showOpenableWorkspace() -> Bool {
        let machines = services.machines
        let members = services.windows.registry.members(of: state.id)
        let openable = { (id: String) -> Bool in
            guard let (workspace, _) = machines.workspace(id: id) else { return false }
            return workspace.kind != "home"
        }
        guard let id = (state.workspaceRecency + members).first(where: openable) else { return false }
        state.showWorkspace(id)
        showWorkspace(requested: id)
        return true
    }
}
