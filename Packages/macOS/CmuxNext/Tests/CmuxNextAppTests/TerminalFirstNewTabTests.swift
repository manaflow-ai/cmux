import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTabs
import Foundation
import Testing

/// #23021: with `tabs.terminalFirst` (cmux Classic Mode) on, a person's Cmd-T, Cmd-D, Cmd-Shift-D
/// and Cmd-N open a terminal, as in cmux classic. Off (the default), Cmd-T opens the New Tab page and a split from the page
/// opens the page again (cx-hvc57, cx-jfo7).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TerminalFirstNewTabTests {
    @Test func terminalFirstOpensTerminalsForCmdTAndSplits() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-23021")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let directory = FileManager.default.temporaryDirectory.appending(path: "cn-23021-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "cmux.json")
            try Data("{}".utf8).write(to: url)
            let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            #expect(settings.snapshot.terminalFirst == false, "off by default")
            services.settings = settings

            let pane = try #require(services.windows.active?.focusedPane)
            let workspace = try #require(pane.workspace?.workspace.id)
            @MainActor func tabs() -> [TabModel] {
                services.daemon.store.workspaces.first { $0.id == workspace }?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
            }
            @MainActor func paneCount() -> Int {
                services.daemon.store.workspaces.first { $0.id == workspace }?.screens.flatMap(\.panes).count ?? 0
            }
            @MainActor func pages() -> [TabModel] { tabs().filter { services.agentTabs.isNewTabPage($0.id) } }
            @MainActor func terminals() -> [TabModel] { tabs().filter { $0.kind == .pty } }
            @MainActor func describe() -> String {
                "tabs: \(tabs().map { "\($0.id) \($0.kind)\(services.agentTabs.isNewTabPage($0.id) ? " page" : "")" }), panes: \(paneCount())"
            }

            // The default: Cmd-T opens the New Tab page, selected in the focused pane. The launch
            // workspace may already show a page (a new workspace starts on one): count the new one.
            let terminalsBefore = terminals().count, before = Set(tabs().map(\.id)), pagesBefore = pages().count
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ pages().count == pagesBefore + 1 }, report: describe)
            let page = try #require(pages().first { !before.contains($0.id) }?.id)
            try await PasswordManagerRouteTests.until({ pane.currentTabKey == page }, report: { "selected: \(pane.currentTabKey ?? "none")" })
            #expect(terminals().count == terminalsBefore, "\(describe())")

            try await settings.set(.bool(true), at: TerminalFirstSetting.configPath)
            try await PasswordManagerRouteTests.until({ services.settings?.snapshot.terminalFirst == true })

            // Cmd-D from the New Tab page: a new pane with a terminal, not another page.
            let panesBefore = paneCount()
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ paneCount() == panesBefore + 1 && terminals().count == terminalsBefore + 1 },
                                                      report: describe)
            #expect(pages().count == pagesBefore + 1, "\(describe())")

            // Cmd-T: a terminal tab, never the page.
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ terminals().count == terminalsBefore + 2 }, report: describe)
            #expect(pages().count == pagesBefore + 1, "\(describe())")

            // Cmd-N: a new workspace whose only tab is a terminal, not the New Tab page.
            let workspacesBefore = Set(services.daemon.store.workspaces.map(\.id))
            #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            @MainActor func created() -> [TabModel]? {
                services.daemon.store.workspaces.first { !workspacesBefore.contains($0.id) }?.screens.flatMap(\.panes).flatMap(\.tabs)
            }
            try await PasswordManagerRouteTests.until({ created()?.isEmpty == false },
                                                      report: { "new workspace tabs: \(String(describing: created()))" })
            let first = try #require(created())
            #expect(first.allSatisfy { $0.kind == .pty && !services.agentTabs.isNewTabPage($0.id) },
                    "new workspace tabs: \(first.map { "\($0.id) \($0.kind)" })")
        }
    }
}
