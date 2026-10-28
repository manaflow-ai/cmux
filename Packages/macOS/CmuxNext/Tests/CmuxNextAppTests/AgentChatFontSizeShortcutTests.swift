import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAgentPane
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
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-chat-font-key")
            try #require(services.agentTabs.canHostChat, "this build has no agent page")
            let root = FileManager.default.temporaryDirectory.appending(path: "cn-chat-font-key-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appending(path: "cmux.json")
            try Data("{}".utf8).write(to: url)
            let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            let key = AgentPaneDisplaySetting.fontSizePath

            // The first tab is a terminal. Its shortcut must not write the chat setting.
            #expect(services.registry.perform("increaseWorkspaceTerminalFontSize", invocation: ActionInvocation(origin: .user)))
            #expect(settings.fileRoot.value(at: key) == nil)

            let pane = try #require(services.windows.active?.focusedPane)
            pane.newAgentTab()
            try await PasswordManagerRouteTests.until({
                guard let focused = services.windows.active?.focusedPane,
                      case .agent = focused.currentContent else { return false }
                return true
            }, report: { "focused content: \(String(describing: services.windows.active?.focusedPane?.currentContent))" })

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
}
