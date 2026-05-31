import AppKit
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            primaryDocsHelpMenuItems
            secondaryDocsHelpMenuItems

            Divider()

            splitCommandButton(title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"), shortcut: menuShortcut(for: .sendFeedback)) {
                presentFeedbackFromHelpMenu()
            }

            Button(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")) {
                AppDelegate.shared?.checkForUpdates(nil)
            }

            Divider()

            helpResourceButton(.githubIssues)
            helpResourceButton(.discord)

            Divider()

            Button(String(localized: "menu.help.keyboardShortcutsSettings", defaultValue: "Keyboard Shortcuts Settings…")) {
                openKeyboardShortcutsFromHelpMenu()
            }
        }
    }

    @ViewBuilder
    private var primaryDocsHelpMenuItems: some View {
        helpResourceButton(.gettingStarted)
        helpResourceButton(.concepts)
        helpResourceButton(.configuration)
        helpResourceButton(.customCommands)
        helpResourceButton(.dock)
        helpResourceButton(.keyboardShortcuts)
        helpResourceButton(.apiReference)
        helpResourceButton(.browserAutomation)
    }

    @ViewBuilder
    private var secondaryDocsHelpMenuItems: some View {
        helpResourceButton(.notifications)
        helpResourceButton(.ssh)
        helpResourceButton(.skills)
        agentIntegrationsHelpMenu
        helpResourceButton(.changelog)
    }

    private var agentIntegrationsHelpMenu: some View {
        Menu(String(localized: "menu.help.agentIntegrations", defaultValue: "Agent Integrations")) {
            helpResourceButton(.claudeCodeTeams)
            helpResourceButton(.ohMyOpenCode)
            helpResourceButton(.ohMyCodex)
            helpResourceButton(.ohMyClaudeCode)
        }
    }

    private func helpResourceButton(_ resource: CmuxHelpResource) -> some View {
        Button(resource.title) {
            NSWorkspace.shared.open(resource.url)
        }
    }

    private func openKeyboardShortcutsFromHelpMenu() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.openPreferencesWindow(
                debugSource: "helpMenu.keyboardShortcuts",
                navigationTarget: .keyboardShortcuts
            )
        } else {
            AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
        }
    }

    private func presentFeedbackFromHelpMenu() {
        if let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            FeedbackComposerBridge.openComposer(in: targetWindow)
            return
        }

        if let targetWindow = AppDelegate.shared?.showMainWindowFromMenuBar() {
            FeedbackComposerBridge.openComposer(in: targetWindow)
        }
    }
}
