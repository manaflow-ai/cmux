import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// cx-lle.6, Chrome's pinned tabs: a pinned browser tab keeps the page it was pinned on. The
/// app's Pin Tab records it on the daemon, the tab reports it after it browses away, and Back to
/// Pinned Page (`browser.resetPinnedTab`, tab menu, palette, `cmux browser back-to-pinned-page`)
/// takes the tab back there. Runs the app's action registry against a same-tree cmux-tui daemon,
/// as the tab menu and the CLI reach it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PinnedPageTests {
    static let pinnedPage = "https://mail.example.com/"
    static let elsewhere = "https://mail.example.com/inbox/42"

    @Test func backToPinnedPageReturnsAPinnedTabToThePageItWasPinnedOn() async throws {
        try await Self.withApp { services, connection in
            let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.handle)
            // A browser tab in the background: its page has not loaded here, so the daemon's record is the page.
            let surface = try await connection.newFrontendBrowserTab(url: Self.pinnedPage, engine: .webkit, in: pane, activate: false).surface
            try await Self.until({ services.daemon.store.tab(surface: surface) != nil }, report: { WindowStateReport.describe(services, surface: surface) })
            let tab = try #require(services.daemon.store.tab(surface: surface))
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
            let menu = services.registry.action(for: "browser.resetPinnedTab")
            #expect(menu != nil, "Back to Pinned Page is not an action")
            #expect(menu?.targetHidden?(target) == true, "an unpinned tab's menu offers Back to Pinned Page")

            // A pin that never lands says whether the handler refused, sent nothing, or the daemon failed it.
            var ran = false
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork { ran = services.registry.perform("palette.toggleTabPin", invocation: target) }
            }
            #expect(ran)
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            try await Self.until({ services.daemon.store.tab(surface: surface)?.pinned == true }, report: {
                "pin refusal \(refusal ?? "none"), pin work \(work.count), failures \(failures); " + WindowStateReport.describe(services, surface: surface)
            })
            // The tab browses away from the page it was pinned on.
            try await connection.updateFrontendBrowserTab(surface, url: Self.elsewhere)
            try await Self.until({ services.daemon.store.tab(surface: surface)?.url == Self.elsewhere }, report: { WindowStateReport.describe(services, surface: surface) })
            #expect(services.daemon.store.tab(surface: surface)?.pinnedURL == Self.pinnedPage)
            #expect(menu?.targetHidden?(target) == false, "the pinned tab's menu leaves out Back to Pinned Page")

            #expect(services.registry.perform("browser.resetPinnedTab", invocation: target))
            try await Self.until({ services.daemon.store.tab(surface: surface)?.url == Self.pinnedPage }, report: { WindowStateReport.describe(services, surface: surface) })
            #expect(services.daemon.store.tab(surface: surface)?.pinnedURL == Self.pinnedPage)
            #expect(menu?.targetHidden?(target) == true, "the tab is on its pinned page: nothing to go back to")
        }
    }

    /// Polls `condition` (the store follows the daemon's events) up to a
    /// deadline. A timeout is reported at the caller's line: which wait it was.
    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(20),
                      report: () -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out: \(report())", sourceLocation: sourceLocation)
    }

    /// The app's services on a fresh same-tree daemon, ready once restore made its first terminal.
    static func withApp(_ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-pinned-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-pinned-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let result: Result<Void, any Error>
        do {
            try await until({ services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }, within: .seconds(90))
            // Actions reach tabs through the window's panes, which attach after the daemon's.
            try await until({ services.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(30))
            result = .success(try await body(services, try #require(services.daemon.connection)))
        } catch { result = .failure(error) }
        // Stop the app's connection first: on the daemon's EOF it would start a
        // fresh daemon that outlives the test. The shutdown uses its own socket.
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        try result.get()
    }
}
