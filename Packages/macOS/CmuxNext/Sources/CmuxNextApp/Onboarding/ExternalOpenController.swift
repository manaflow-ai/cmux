import AppKit
import CmuxNextOnboarding

/// Opens what macOS hands cmux as the default browser, the `ssh:` and
/// `x-man-page:` handler, a script's opener or the Finder service: a tab in
/// the current window's focused pane, per `ExternalOpenRouter`. Requests that
/// arrive before a window has content (a cold launch by a link) wait and run
/// when the first window shows its workspace.
@MainActor
final class ExternalOpenController {
    unowned let services: AppServices
    let router = ExternalOpenRouter()
    private(set) var pending: [ExternalOpenRoute] = []

    init(services: AppServices) {
        self.services = services
    }

    /// Returns false for a URL cmux does not open (the caller refuses it).
    @discardableResult
    func open(_ url: URL) -> Bool {
        let route = router.route(url)
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
        guard case .terminal(let cwd, _) = router.newTabHere(path), let windows = services.windows else { return }
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
        guard let windows = services.windows else { return pending.append(route) }
        guard let controller = windows.active, let pane = controller.focusedPane else {
            pending.append(route)
            if windows.restored, windows.controllers.isEmpty { windows.reopenOrCreateWindow() }
            return
        }
        deliver(route, to: pane)
        windows.bringToFront(controller)
        if !services.environment.noActivate { NSApp.activate() }
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
        case .deepLink, .unsupported: return
        }
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

    @objc func newTabHere(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open.newTabHere(Self.paths(pasteboard))
    }

    @objc func openTab(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        for path in Self.paths(pasteboard) { open.newWorkspace(at: path, newWindow: false) }
    }

    @objc func openWindow(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
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
