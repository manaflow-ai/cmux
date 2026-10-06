import AppKit
import CmuxAppKitSupportUI
import CmuxSettingsUI
import SwiftUI

enum SidebarAccountChipMetrics {
    static let height: CGFloat = 26
    static let avatarSize: CGFloat = 18
    static let minNameWidth: CGFloat = 72
    static let chevronPointSize: CGFloat = 11
}

/// The sidebar footer's one menu button, like the account row in Claude and
/// ChatGPT desktop: a full-width chip whose native menu holds the account,
/// app settings, help and feedback. There is no separate Help button.
///
/// Signed in it shows the avatar and name; signed out, a person icon and
/// "Account", with Sign In… first in the menu; with the account button flag
/// off, a ? icon and "Help". One chevron at the trailing edge, pointing the way the
/// menu opens, marks where the target ends.
struct SidebarFooterMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    @Environment(BrowserDataImportCoordinator.self) private var browserDataImportCoordinator: BrowserDataImportCoordinator?
    let onSendFeedback: () -> Void
    /// False when the footer is too narrow for the label: icon and chevron.
    var showsName = true
    @State private var menuAnchor = SidebarFooterMenuAnchor()
    /// The keyboard shortcut cheat sheet, anchored to this button.
    @State private var isShortcutsPopoverPresented = false
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private var showsAccount: Bool { CmuxFeatureFlags.shared.isSidebarAccountButtonEnabled }
    private var billingPlanRefreshID: String? {
        guard let flow = accountFlow, let accountID = flow.currentIdentity?.id else { return nil }
        return "\(accountID):\(flow.confirmedTeamID ?? "personal"):\(flow.isProUpgradeAvailable)"
    }
    private let accountTitle = String(localized: "settings.section.account", defaultValue: "Account")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
#if DEBUG
    @AppStorage(SidebarFooterProfileIconDebugSettings.sizeKey)
    private var debugIconSize = SidebarFooterProfileIconDebugSettings.defaultSize
    @AppStorage(SidebarFooterProfileDisplayDebugSettings.displayKey)
    private var debugProfileDisplay = SidebarFooterProfileDisplayDebugSettings.defaultDisplay.rawValue
#endif

    private var profileIconSize: CGFloat {
#if DEBUG
        CGFloat(debugIconSize)
#else
        SidebarFooterButtonMetrics.profileIconSize
#endif
    }

    private var prefersProfileIcon: Bool {
#if DEBUG
        SidebarFooterProfileDisplayDebugChoice(rawValue: debugProfileDisplay) == .icon
#else
        false
#endif
    }

    private func presentation(
        isSignedIn: Bool,
        hasProfilePicture: Bool
    ) -> SidebarAccountButtonPresentation {
        let presentation = SidebarAccountButtonPresentation.resolve(
            isSignedIn: isSignedIn,
            prefersProfileIcon: prefersProfileIcon,
            hasProfilePicture: hasProfilePicture
        )
#if DEBUG
        if !presentation.showsProfilePicture {
            return SidebarAccountButtonPresentation(
                visual: presentation.visual,
                size: profileIconSize
            )
        }
#endif
        return presentation
    }

    var body: some View {
        let identity = showsAccount ? accountFlow?.currentIdentity : nil
        let label = identity.map(chipName(for:)) ?? (showsAccount ? accountTitle : helpTitle)
        let buttonTitle = showsAccount ? accountTitle : helpTitle
        Button {
            menuAnchor.popUp(makeMenu(identity: identity))
        } label: {
            HStack(spacing: 5) {
                icon(identity: identity)
                    .frame(width: SidebarAccountChipMetrics.avatarSize, height: SidebarAccountChipMetrics.avatarSize)
                    .overlay(alignment: .topTrailing) {
                        // Quiet What's New: a static dot, no motion, cleared once opened.
                        if WhatsNewCenter.shared.hasUnseenHighlights {
                            SidebarWhatsNewDot()
                                .offset(x: 2, y: -2)
                        }
                    }
                if showsName {
                    Text(label)
                        .cmuxFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Ideal width is a floor, not the whole name, so the
                        // footer keeps the name (truncated) down to a short
                        // stub before it falls back to icon and chevron.
                        .frame(idealWidth: SidebarAccountChipMetrics.minNameWidth, maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                CmuxSystemSymbolImage(
                    systemName: "chevron.up",
                    pointSize: SidebarAccountChipMetrics.chevronPointSize,
                    weight: .medium,
                    tint: Color(nsColor: .secondaryLabelColor)
                )
            }
            .padding(.leading, 2)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, minHeight: SidebarAccountChipMetrics.height, maxHeight: SidebarAccountChipMetrics.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SidebarFooterMenuAnchorView(anchor: menuAnchor))
        .safeHelp(buttonTitle)
        .accessibilityLabel(buttonTitle)
        .accessibilityValue(identity.map(chipName(for:)) ?? "")
        .accessibilityIdentifier("SidebarAccountMenuButton")
        // Outermost, so the identifier above stays on the button itself.
        .popover(isPresented: $isShortcutsPopoverPresented, arrowEdge: .top) {
            AllShortcutsPopover()
        }
        .task(id: billingPlanRefreshID) {
            guard let flow = accountFlow,
                  flow.isAuthenticated,
                  flow.isProUpgradeAvailable else { return }
            await flow.refreshBillingPlan()
        }
    }

    @ViewBuilder
    private func icon(identity: AccountIdentity?) -> some View {
        if showsAccount {
            let profile = presentation(isSignedIn: identity != nil, hasProfilePicture: identity?.avatarURL != nil)
            SidebarAccountAvatar(
                avatarURL: identity?.avatarURL,
                displayName: identity?.displayName ?? "",
                email: identity?.email ?? "",
                isSignedIn: profile.showsProfilePicture,
                size: profile.showsProfilePicture ? SidebarAccountChipMetrics.avatarSize : profile.size
            )
        } else {
            SidebarFooterHelpIcon(pointSize: SidebarFooterButtonMetrics.helpIconSize, weight: SidebarFooterCircularIconStyle.standard.weight)
        }
    }

    private func chipName(for identity: AccountIdentity) -> String {
        identity.displayName.isEmpty ? identity.email : identity.displayName
    }

    /// Who you are (or Sign In…), then the app, then help and feedback, then
    /// upkeep, then the upsell, with Sign Out last and apart so it is never
    /// the item under a hurried click.
    private func makeMenu(identity: AccountIdentity?) -> NSMenu {
        let flow = accountFlow
        let menu = NSMenu(title: showsAccount ? accountTitle : helpTitle)
        menu.autoenablesItems = false

        if showsAccount {
            if let identity {
                let header = NSMenuItem()
                header.isEnabled = false
                let headerView = NSHostingView(rootView: SidebarAccountMenuHeader(
                    avatarURL: identity.avatarURL,
                    displayName: identity.displayName,
                    email: identity.email,
                    isPro: flow?.isProActive == true
                ))
                headerView.frame.size = headerView.fittingSize
                headerView.autoresizingMask = [.width]
                header.view = headerView
                menu.addItem(header)
            } else {
                let tabManager = tabManager
                let signIn = menu.addSidebarFooterItem(
                    String(localized: "settings.account.signIn", defaultValue: "Sign In…"),
                    identifier: "SidebarAccountSignInButton",
                    symbol: "person.crop.circle"
                ) {
                    _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "sidebar.account"
                    )
                }
                signIn.isEnabled = flow?.isWorkingOnAuth != true
            }
            menu.addSidebarFooterSeparator()
        }

        // Capture the binding rather than this view. The anchor keeps the menu
        // alive and `@State` keeps the anchor alive, so a handler that captured
        // `self` would close a cycle through the state's storage and hold the
        // menu, its hosting-view header and the rest of what it captures for
        // good. A binding refers to that storage, not to the view.
        let shortcutsPresented = $isShortcutsPopoverPresented
        SidebarHelpMenuItems.addApp(to: menu) {
            shortcutsPresented.wrappedValue = true
        }
        menu.addSidebarFooterSeparator()
        SidebarHelpMenuItems.addHelp(to: menu, onSendFeedback: onSendFeedback)
        menu.addSidebarFooterSeparator()
        SidebarHelpMenuItems.addMaintenance(to: menu, browserDataImportCoordinator: browserDataImportCoordinator)

        let offersUpgrade = SidebarFooterPresentationPolicy.isUpgradeVisible(
            featureFlagEnabled: flow?.isProUpgradeAvailable
                ?? CmuxFeatureFlags.shared.isProUpgradeUIEnabled,
            isProActive: flow?.isProActive == true
        )
        if offersUpgrade {
            menu.addSidebarFooterSeparator()
            menu.addSidebarFooterItem(
                String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                identifier: "SidebarHelpMenuOptionUpgrade",
                symbol: "star"
            ) {
                if let flow, identity != nil {
                    flow.openProUpgrade(source: .sidebarAccountMenu)
                } else {
                    ProUpgradePresenter.present(source: .sidebarHelpMenu)
                }
            }
        }

        if identity != nil {
            menu.addSidebarFooterSeparator()
            let signOut = menu.addSidebarFooterItem(
                String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
                identifier: "SidebarAccountSignOutButton",
                symbol: "rectangle.portrait.and.arrow.right"
            ) {
                Task { await flow?.signOut() }
            }
            // The popover this replaces disabled itself while auth was in
            // flight, which covered Sign Out as well as Sign In.
            signOut.isEnabled = flow?.isWorkingOnAuth != true
        }
        return menu
    }
}

/// Identity header for the account menu: the same avatar as the footer
/// button, larger, beside the name and email it stands for.
private struct SidebarAccountMenuHeader: View {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let isPro: Bool

    var body: some View {
        HStack(spacing: 10) {
            SidebarAccountAvatar(
                avatarURL: avatarURL,
                displayName: displayName,
                email: email,
                isSignedIn: true,
                size: 28
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayName.isEmpty ? email : displayName)
                        .cmuxFont(size: 13, weight: .semibold)
                        .lineLimit(1)
                    if isPro {
                        // Product name ("cmux Pro"), the same in every locale.
                        // The plan lives here rather than on the chip, which
                        // stays short enough to keep its name in a narrow sidebar.
                        Text(verbatim: "Pro")
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }
                if !email.isEmpty && email != displayName {
                    Text(email)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minWidth: 220, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SidebarAccountMenuHeader")
    }
}
