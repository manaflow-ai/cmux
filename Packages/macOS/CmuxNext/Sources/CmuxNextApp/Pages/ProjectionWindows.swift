import AppKit
import CmuxNextActions
import CmuxNextAppCore
import CmuxNextPages
import Foundation

/// Projection windows (manaflow-ai/cmuxterm-hq#7149 L10; ``WebProjection``, CmuxNextPages): a real
/// window of this app whose pages and agent panes load from a worktree's dev server, beside the
/// windows the person works in, which keep their pages. It has their settings, theme, backdrop and
/// keys and the live daemon's terminals, since it is the same app. Leo, 2026-11-05: "there's even the
/// glass, like the actual glass with your actual config, your actual settings. That's the point."
///
/// - `debug.projection` (Debug > Open Projection Window; `cmux action run debug.projection --server
///   http://127.0.0.1:4290/ --worktree ~/src/wt --test 'bun test src/x.test.ts'`, which
///   `scripts/cmux-next/projection.sh` runs): a new window, its first workspace a terminal in the
///   worktree, bound to `server` (default the `web-overlay.sh` port). Saving a web file there
///   hot-reloads that window only.
/// - `debug.projection.runTest` (Debug > Run Projection Test): one click runs the projection's test
///   command (`test`, from the open or this run) in a new workspace of the projection window, in its
///   worktree, kept open with its output.
///
/// NIGHTLY, cmux NEXT DEV and Debug only (``WebDevOverride/isEnabled``).
@MainActor
final class ProjectionWindows {
    static let openID = "debug.projection"
    static let runTestID = "debug.projection.runTest"
    /// The port `web-overlay.sh server` uses; `projection.sh` passes its own.
    static let defaultServer = "http://127.0.0.1:4200/"

    struct Projection {
        let windowID: String
        let server: PageDevServer
        var worktree: String?
        var test: String?
    }

    private weak var services: AppServices?
    /// Open projections, newest last.
    private(set) var projections: [Projection] = []
    private var closeObservers: [String: NSObjectProtocol] = [:]

    init(services: AppServices) { self.services = services }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let projections = ProjectionWindows(services: context.services)
        registry.bindEffect(ActionID(rawValue: openID), unavailable: { unavailableReason }) { invocation in
            projections.open(server: invocation["server"]?.stringValue, worktree: invocation["worktree"]?.stringValue,
                             test: invocation["test"]?.stringValue).map { ActionEffect.refused($0) } ?? .done
        }
        registry.bindEffect(ActionID(rawValue: runTestID), unavailable: { unavailableReason }) { invocation in
            projections.runTest(invocation["test"]?.stringValue).map { ActionEffect.refused($0) } ?? .done
        }
    }

    /// Opens one projection window. The refusal, or nil when it opens (the window shows once the daemon
    /// lists its workspace, and is bound then).
    func open(server: String?, worktree: String?, test: String?) -> String? {
        guard let services else { return nil }
        let raw = server.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultServer
        guard let root = PageDevServer.loopbackURL(raw) else { return Self.notLoopback }
        let worktree = worktree.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        let projection = Projection(windowID: UUID().uuidString.lowercased(), server: PageDevServer(root: root),
                                    worktree: worktree, test: test.flatMap { $0.isEmpty ? nil : $0 })
        projections.append(projection)
        var spawn = WorkspaceSpawn(cwd: worktree, name: Self.workspaceName(worktree))
        spawn.opensNewTabPage = true
        let create = services.windows.startWorkspace(spawn, into: projection.windowID)
        Task { [weak self] in // task-owner: the window's create, then its bind once it shows
            _ = try? await create()
            await self?.bindWhenShown(projection.windowID)
        }
        return nil
    }

    /// Runs the newest projection's test (or `test`) in a new workspace of its window.
    func runTest(_ test: String?) -> String? {
        guard let services else { return nil }
        let active = services.windows.active?.state.id
        guard let index = projections.lastIndex(where: { $0.windowID == active }) ?? projections.indices.last
        else { return Self.noProjection }
        if let test, !test.isEmpty { projections[index].test = test }
        let projection = projections[index]
        guard let command = projection.test else { return Self.noTest }
        let spawn = WorkspaceSpawn(cwd: projection.worktree, name: Self.testName, command: command, keep: true)
        let create = services.windows.startWorkspace(spawn, into: projection.windowID)
        Task { _ = try? await create() } // task-owner: the test workspace's daemon create
        return nil
    }

    /// Binds the projection's window once its controller has one (a new window shows when the daemon
    /// lists its first workspace), for up to 10 s.
    private func bindWhenShown(_ windowID: String) async {
        for _ in 0..<200 {
            if let window = services?.windows.controller(for: windowID)?.window,
               let projection = projections.first(where: { $0.windowID == windowID }) {
                WebProjection.shared.bind(window, server: projection.server)
                closeObservers[windowID] = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closed(windowID, window: window) }
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        projections.removeAll { $0.windowID == windowID }
    }

    private func closed(_ windowID: String, window: NSWindow) {
        WebProjection.shared.unbind(window)
        projections.removeAll { $0.windowID == windowID }
        if let observer = closeObservers.removeValue(forKey: windowID) { NotificationCenter.default.removeObserver(observer) }
    }

    static func workspaceName(_ worktree: String?) -> String {
        let folder = worktree.flatMap(WorkspaceSpawn.folderName)
        return folder.map { String(format: t("projection.workspace.named", "Projection: %@"), $0) } ?? t("projection.workspace", "Projection")
    }

    static var unavailableReason: String? {
        WebDevOverride.isEnabled ? nil : t("projection.refusal.off", "Projection windows are only in NIGHTLY and DEV builds.")
    }
    static var notLoopback: String { t("projection.refusal.notLoopback", "The projection's server must be a local address.") }
    static var noProjection: String { t("projection.refusal.none", "No projection window is open.") }
    static var noTest: String { t("projection.refusal.noTest", "This projection has no test. Pass one with --test.") }
    static var testName: String { t("projection.workspace.test", "Projection Test") }

    private nonisolated static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
