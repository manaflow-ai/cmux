import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Lawrence via Leo: "make sure font size everywhere (like text input area) is customizable".
/// The same action bound to Cmd +/− scales chat text when a chat owns focus, and keeps the
/// workspace terminal path when it does not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentChatFontSizeShortcutTests {
    @Test func fontActionsWriteTheChatSettingOnlyInAChat() async throws {
        try await withSettings { services, settings, _ in
            let key = AgentPaneDisplaySetting.fontSizePath

            // Startup may land on a chat. Select a real terminal before testing its shortcut,
            // or an asynchronous chat-font write can leak into the two-press assertion below.
            let pane = try #require(services.windows.active?.focusedPane)
            pane.newTerminalTab()
            try await PasswordManagerRouteTests.until({
                guard let focused = services.windows.active?.focusedPane,
                      case .terminal = focused.currentContent else { return false }
                return true
            })
            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            #expect(services.agentChatFontSizeWrites.latest == nil)
            #expect(settings.fileRoot.value(at: key) == nil)

            try await openChat(services)

            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ settings.fileRoot.value(at: key) == .number(16) },
                                                       report: { "two quick increases saved \(String(describing: settings.fileRoot.value(at: key)))" })
            #expect(services.registry.perform("decreaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ settings.fileRoot.value(at: key) == .number(15) })

            try await settings.set(.number(28), at: key)
            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            #expect(await services.agentChatFontSizeWrites.latest?.value == nil)
            #expect(settings.fileRoot.value(at: key) == .number(28), "the upper Settings limit is kept")
            #expect(services.registry.perform("resetWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ settings.fileRoot.value(at: key) == nil })
        }
    }

    @Test func managedFontActionsRefuseWithoutWriting() async throws {
        let key = AgentPaneDisplaySetting.fontSizePath
        let dotted = key.joined(separator: ".")
        try await withSettings(managed: ManagedPreferences(forced: [dotted: .number(22)])) { services, settings, url in
            try await openChat(services)
            #expect(settings.managedKey(forPath: key) != nil)
            var notices: [(String, Bool)] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { notices.append(($0, $1)) }
            defer { services.registry.refusalObserver = previous }
            for id: ActionID in ["increaseWorkspaceTerminalFontSize", "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize"] {
                #expect(services.registry.perform(id, invocation: ActionInvocation(origin: .user)))
            }
            #expect(notices.count == 3)
            #expect(notices.allSatisfy { $0.0.contains(dotted) && !$0.1 })
            #expect(services.agentChatFontSizeWrites.latest == nil)
            #expect(settings.fileRoot.value(at: key) == nil)
            #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
        }
    }

    @Test func aNonChatKeySurfaceDoesNotBorrowTheSelectedChat() async throws {
        try await withSettings { services, settings, _ in
            try await openChat(services)

            // The pane is still selected, but a sidebar/native control owns the key event.
            // The workspace-font action must stay on its terminal path instead of changing the
            // selected chat's setting.
            var invocation = ActionInvocation(origin: .user)
            invocation.keyContext = [.rightSidebarFocused]
            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: invocation))
            try await Task.sleep(for: .milliseconds(50))
            #expect(settings.fileRoot.value(at: AgentPaneDisplaySetting.fontSizePath) == nil)

            invocation.keyContext = [.agentPaneFocused]
            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: invocation))
            try await PasswordManagerRouteTests.until({
                settings.fileRoot.value(at: AgentPaneDisplaySetting.fontSizePath) == .number(15)
            })
        }
    }

    @Test(arguments: [false, true]) func failedFontWritesReachTheKeyboardOrWaitingCaller(captured: Bool) async throws {
        try await withSettings { services, settings, url in
            try await openChat(services)
            // A broken user file must remain untouched, and the failed write must not be silent.
            try Data("{".utf8).write(to: url)
            var notices: [(String, Bool)] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { notices.append(($0, $1)) }
            defer { services.registry.refusalObserver = previous }
            if captured {
                let work = services.registry.capturingWork {
                    #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
                }
                #expect(work.count == 1)
                let task = try #require(work.first)
                let failure = try #require(await task.value)
                #expect(!failure.message.isEmpty)
                #expect(notices.isEmpty, "the waiting caller receives the failure without a duplicate notice")
            } else {
                #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
                let task = try #require(services.agentChatFontSizeWrites.latest)
                #expect(await task.value != nil)
                try await PasswordManagerRouteTests.until({ notices.count == 1 }, report: { "a failed keyboard write showed \(notices.count) refusals" })
                #expect(notices.first?.0.isEmpty == false && notices.first?.1 == false)
            }
            #expect(settings.fileRoot.value(at: AgentPaneDisplaySetting.fontSizePath) == nil)
            #expect(try String(contentsOf: url, encoding: .utf8) == "{")
        }
    }

    private func withSettings(managed: ManagedPreferences = ManagedPreferences(),
                              _ body: (AppServices, SettingsController, URL) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-chat-font-key")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let root = FileManager.default.temporaryDirectory.appending(path: "cn-chat-font-key-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appending(path: "cmux.json")
            try Data("{}".utf8).write(to: url)
            let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            try await body(services, settings, url)
        }
    }

    private func openChat(_ services: AppServices) async throws {
        let pane = try #require(services.windows.active?.focusedPane)
        pane.newAgentTab()
        try await PasswordManagerRouteTests.until({
            guard let focused = services.windows.active?.focusedPane,
                  case .agent = focused.currentContent else { return false }
            return true
        }, report: { "focused content: \(String(describing: services.windows.active?.focusedPane?.currentContent))" })
    }
}
