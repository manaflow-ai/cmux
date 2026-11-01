import AppKit
import CmuxNextAccounts
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCodeRouter
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Accounts must open its provider command even when no existing window has a local pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct AccountsLocalLoginIntegrationTests {
    @Test func thePaletteAndCLIReachTheLoginWithNoMainWindow() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))
        AppActions.bind(services)
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork {
                _ = services.registry.perform("accounts.reauthenticate", invocation: ActionInvocation(
                    arguments: ["provider": .string("codex")], origin: .cli))
            }
        }
        #expect(refusal == nil)
        #expect(!work.isEmpty, "the action refused before the model could choose a local workspace")
        for task in work { #expect(await task.value == nil) }
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
          arguments: [false, true], [false, true])
    func aProviderLoginCreatesALocalWorkspaceWhenNoWindowCanTakeIt(page: Bool, terminalFirst: Bool) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let root = FileManager.default.temporaryDirectory.appending(path: "accounts-settings-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appending(path: "cmux.json")
            try Data("{\"tabs\":{\"terminalFirst\":\(terminalFirst)}}".utf8).write(to: url)
            let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            for controller in services.windows.controllers { controller.window?.close() }
            try #require(services.windows.controllers.isEmpty)
            let before = Set(services.machines.local.store.workspaces.map(\.id))
            // A harmless stand-in for the provider's login: never touch real credentials.
            let pageURL = try #require(URL(string: "about:blank"))
            let plan: ReauthPlan = page ? .page(pageURL) : .command(["true"])
            let opened = await services.accounts.reauthenticate(.codex, plan: plan)
            #expect(opened, "Accounts refused the login because it could not find an existing local pane")
            if opened {
                try await PinnedPageTests.until({
                    services.machines.local.store.workspaces.contains { !before.contains($0.id) && $0.name == "Provider sign-in" }
                }, report: { "the provider command did not create a local workspace" })
                if page {
                    try await PinnedPageTests.until({
                        services.machines.local.store.workspaces.filter { !before.contains($0.id) }
                            .flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                            .contains { $0.kind == .browser && $0.url == pageURL.absoluteString }
                    }, report: { "the workspace exists but its provider browser tab never opened" })
                }
            }
        }
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func anExistingPaneWaitsForTheTerminalAndSendsTheCommand() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            let before = Set(pane.pane.tabs.map(\.id))
            // The marker is constructed by printf, so echoing the typed command cannot satisfy it.
            #expect(await services.accounts.reauthenticate(.codex, plan: .command(["printf", "%s%s\\n", "accounts-", "opened"])))
            try #require(await services.daemon.appliedThroughReply(on: connection, after: "provider terminal test"))
            let tab = try #require(pane.pane.tabs.first { !before.contains($0.id) && $0.kind == .pty })
            let output = try await connection.request(WaitForTextRequest(surface: tab.surface, pattern: "accounts-opened", timeoutMs: 5000))
            #expect(output.matched == true)
        }
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func anExistingPaneReportsTheDaemonsCreationFailure() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            // A stale/provisional pane can still be mounted after its daemon pane disappeared.
            pane.pane.handle = PaneID(rawValue: UInt64.max)
            defer { pane.pane.handle = handle }
            #expect(await services.accounts.reauthenticate(.codex, plan: .command(["true"])) == false)
        }
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func anExistingDisconnectedPaneDoesNotClaimTheLoginOpened() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            services.daemon.shutdownConnection()
            #expect(pane.daemon.connection == nil)
            let opened = await services.accounts.reauthenticate(.codex, plan: .command(["true"]))
            // The harness cannot see the detached connection; clean up this owned daemon here.
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
            #expect(opened == false)
        }
    }
}
