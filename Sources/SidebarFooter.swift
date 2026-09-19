import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Bonsplit
import Combine
import CmuxSidebarInterpreterClient
import CmuxTerminal
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettingsUI
import CmuxSidebar
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

struct SidebarFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    let onSendFeedback: () -> Void

    var body: some View {
#if DEBUG
        SidebarDevFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, modifierKeyMonitor: modifierKeyMonitor, onSendFeedback: onSendFeedback)
#else
        SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, modifierKeyMonitor: modifierKeyMonitor, onSendFeedback: onSendFeedback)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
#endif
    }
}

struct SidebarFooterButtons: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    let onSendFeedback: () -> Void
    @State private var extensionBrowserAnchorView: NSView?
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    // Reuse the exact Command-hold shortcut-hint signal that drives the per-row
    // shortcut badges (`showModifierHoldHints && modifierKeyMonitor.isModifierPressed`,
    // see `resolvedShowsModifierShortcutHints`). Reading `isModifierPressed`
    // (the monitor is `@Observable`) here localizes the reveal re-render to the
    // footer instead of the whole sidebar body.
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    /// Owns the discovery popover so it persists after ⌘ is released.
    @State private var isShortcutPopoverPresented = false

    private var presentationMode: WorkspacePresentationModeSettings.Mode {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode)
    }

    private func shows(_ control: SidebarFooterControl) -> Bool {
        SidebarFooterPresentationPolicy.isVisible(control, presentationMode: presentationMode)
    }

    var body: some View {
        HStack(spacing: 4) {
            if shows(.account) || shows(.mobileConnect) || shows(.help) {
                HStack(spacing: 0) {
                    if shows(.account), CmuxFeatureFlags.shared.isSidebarAccountButtonEnabled {
                        SidebarAccountMenuButton()
                    }
                    if shows(.mobileConnect), CmuxFeatureFlags.shared.isMobileConnectButtonEnabled {
                        SidebarMobileConnectButton()
                    }
                    if shows(.help) {
                        SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
                    }
                }
            }
            // Command-hold reveal: appears immediately before Upgrade. It stays
            // mounted while its popover is open so releasing ⌘ does not dismiss it.
            if shows(.shortcutDiscovery),
               (showModifierHoldHints && modifierKeyMonitor.isModifierPressed) || isShortcutPopoverPresented {
                ShortcutDiscoveryButton(isPopoverPresented: $isShortcutPopoverPresented)
            }
            if shows(.upgrade) {
                SidebarProBadge()
            }
            // The puzzle button opens the extensions browser; it only shows
            // while the experimental Extensions feature is enabled.
            if shows(.extensions), extensionsExperimentalEnabled {
                Button {
                    _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                        from: extensionBrowserAnchorView,
                        title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
                    )
                } label: {
                    CmuxSystemSymbolImage(magnified: "puzzlepiece.extension", pointSize: 12, weight: .medium, tint: Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(SidebarFooterIconButtonStyle())
                .frame(width: 22, height: 22, alignment: .center)
                .safeHelp(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityLabel(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityIdentifier("SidebarExtensionMenuButton")
                .background(TitlebarControlAnchorView { extensionBrowserAnchorView = $0 })
            }
            if shows(.update), let updateActionsHost = AppDelegate.shared {
                UpdatePill(model: updateViewModel, accent: cmuxAccentColor(), actions: updateActionsHost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SidebarHelpMenuAction {
    case upgrade
    case importBrowserData
    case keyboardShortcuts
    case docs
    case changelog
    case github
    case githubIssues
    case discord
    case checkForUpdates
    case sendFeedback
    case welcome
}

private struct SidebarHelpMenuButton: View {
    private let docsURL = URL(string: "https://cmux.com/docs")
    private let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
#if DEBUG
    @AppStorage(SidebarFooterHelpIconDebugSettings.sizeKey)
    private var debugIconSize = SidebarFooterHelpIconDebugSettings.defaultSize
    @AppStorage(SidebarFooterHelpIconDebugSettings.weightKey)
    private var debugIconWeight = SidebarFooterHelpIconDebugSettings.defaultWeight.rawValue
#endif
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private var iconSize: CGFloat {
#if DEBUG
        CGFloat(debugIconSize)
#else
        SidebarFooterButtonMetrics.helpIconSize
#endif
    }

    private var iconWeight: Font.Weight {
#if DEBUG
        SidebarFooterHelpIconDebugWeight(rawValue: debugIconWeight)?.fontWeight
            ?? SidebarFooterCircularIconStyle.standard.weight
#else
        SidebarFooterCircularIconStyle.standard.weight
#endif
    }

    private var sendFeedbackShortcutHint: String {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .sendFeedback).displayString
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            SidebarFooterHelpIcon(pointSize: iconSize, weight: iconWeight)
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            helpOptionButton(
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
                action: .welcome,
                accessibilityIdentifier: "SidebarHelpMenuOptionWelcome",
                isExternalLink: false
            )
            if CmuxFeatureFlags.shared.isProUpgradeUIEnabled {
                helpOptionButton(
                    title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                    action: .upgrade,
                    accessibilityIdentifier: "SidebarHelpMenuOptionUpgrade",
                    isExternalLink: false,
                    trailingSystemImage: "sparkles"
                )
            }
            helpOptionButton(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                action: .sendFeedback,
                accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right"
            )
            helpOptionButton(
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                action: .keyboardShortcuts,
                accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
                action: .importBrowserData,
                accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData",
                isExternalLink: false
            )
            if docsURL != nil {
                helpOptionButton(
                    title: String(localized: "about.docs", defaultValue: "Docs"),
                    action: .docs,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDocs",
                    isExternalLink: true
                )
            }
            if changelogURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                    action: .changelog,
                    accessibilityIdentifier: "SidebarHelpMenuOptionChangelog",
                    isExternalLink: true
                )
            }
            if githubURL != nil {
                helpOptionButton(
                    title: String(localized: "about.github", defaultValue: "GitHub"),
                    action: .github,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHub",
                    isExternalLink: true
                )
            }
            if githubIssuesURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
                    action: .githubIssues,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues",
                    isExternalLink: true
                )
            }
            if discordURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.discord", defaultValue: "Discord"),
                    action: .discord,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDiscord",
                    isExternalLink: true
                )
            }
            helpOptionButton(
                title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                action: .checkForUpdates,
                accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                isExternalLink: false
            )
        }
        .padding(8)
        .frame(minWidth: 200)
    }

    private func helpOptionButton(
        title: String,
        action: SidebarHelpMenuAction,
        accessibilityIdentifier: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        Button {
            isPopoverPresented = false
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .cmuxFont(size: 12)
                Spacer(minLength: 0)
                if let shortcutHint {
                    helpOptionShortcutHint(text: shortcutHint)
                }
                if let trailingSystemImage {
                    helpOptionTrailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    helpOptionTrailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func helpOptionShortcutHint(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .cmuxFont(size: 10, weight: .regular, design: .rounded)
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func helpOptionTrailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        CmuxSystemSymbolImage(systemName: systemName, pointSize: size, tint: Color(nsColor: .secondaryLabelColor))
    }

    private func perform(_ action: SidebarHelpMenuAction) {
        switch action {
        case .upgrade:
            ProUpgradePresenter.present(source: .sidebarHelpMenu)
        case .importBrowserData:
            isPopoverPresented = false
            DispatchQueue.main.async {
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        case .keyboardShortcuts:
            isPopoverPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openPreferencesWindow(
                            debugSource: "sidebarHelpMenu.keyboardShortcuts",
                            navigationTarget: .keyboardShortcuts
                        )
                    } else {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                    }
                }
            }
        case .docs:
            guard let docsURL else { return }
            NSWorkspace.shared.open(docsURL)
        case .changelog:
            guard let changelogURL else { return }
            NSWorkspace.shared.open(changelogURL)
        case .github:
            guard let githubURL else { return }
            NSWorkspace.shared.open(githubURL)
        case .githubIssues:
            guard let githubIssuesURL else { return }
            NSWorkspace.shared.open(githubIssuesURL)
        case .discord:
            guard let discordURL else { return }
            NSWorkspace.shared.open(discordURL)
        case .checkForUpdates:
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        case .sendFeedback:
            isPopoverPresented = false
            onSendFeedback()
        case .welcome:
            isPopoverPresented = false
            Task { @MainActor in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openWelcomeWorkspace()
                }
            }
        }
    }

}
