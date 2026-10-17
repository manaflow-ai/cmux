import AppKit
import CmuxAppKitSupportUI
import CmuxSettingsUI
import SwiftUI

/// The compact sidebar account button for account-level actions. Signed out,
/// a click starts sign-in; signed in, it opens a native account menu (see
/// `SidebarFooterMenuAnchor` for why the footer uses `NSMenu`).
struct SidebarAccountMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private let title = String(localized: "settings.section.account", defaultValue: "Account")
    private let signInTitle = String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    @State private var menuAnchor = SidebarFooterMenuAnchor()
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
        let identity = accountFlow?.currentIdentity
        let isSignedIn = identity != nil
        let buttonTitle = isSignedIn ? title : signInTitle
        let profile = presentation(
            isSignedIn: isSignedIn,
            hasProfilePicture: identity?.avatarURL != nil
        )
        Button {
            if let identity {
                menuAnchor.popUp(makeMenu(
                    avatarURL: identity.avatarURL,
                    displayName: identity.displayName,
                    email: identity.email
                ))
            } else {
                _ = AppDelegate.shared?.performAccountSignInWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "sidebar.account"
                )
            }
        } label: {
            SidebarAccountAvatar(
                avatarURL: identity?.avatarURL,
                displayName: identity?.displayName ?? "",
                email: identity?.email ?? "",
                isSignedIn: profile.showsProfilePicture,
                size: profile.size
            )
            .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .frame(width: buttonSize, height: buttonSize)
        .background(SidebarFooterMenuAnchorView(anchor: menuAnchor))
        .safeHelp(buttonTitle)
        .accessibilityLabel(buttonTitle)
        .accessibilityIdentifier("SidebarAccountMenuButton")
    }

    /// Who you are, then what you can do with the account, then Sign Out
    /// last and apart so it is never the item under a hurried click.
    private func makeMenu(avatarURL: URL?, displayName: String, email: String) -> NSMenu {
        let flow = accountFlow
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false

        let header = NSMenuItem()
        header.isEnabled = false
        let headerView = NSHostingView(rootView: SidebarAccountMenuHeader(
            avatarURL: avatarURL,
            displayName: displayName,
            email: email
        ))
        headerView.frame.size = headerView.fittingSize
        headerView.autoresizingMask = [.width]
        header.view = headerView
        menu.addItem(header)
        menu.addSidebarFooterSeparator()

        menu.addSidebarFooterItem(
            String(localized: "menu.app.settings", defaultValue: "Settings…"),
            identifier: "SidebarAccountSettingsButton",
            shortcut: KeyboardShortcutSettings.shortcut(for: .openSettings)
        ) {
            AppDelegate.shared?.openPreferencesWindow(
                debugSource: "sidebar.account.settings",
                navigationTarget: .account
            )
        }
        if flow?.isProUpgradeAvailable == true {
            menu.addSidebarFooterItem(
                String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                identifier: "SidebarAccountUpgradeButton"
            ) {
                flow?.openProUpgrade(source: .sidebarAccountMenu)
            }
        }

        menu.addSidebarFooterSeparator()
        menu.addSidebarFooterItem(
            String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
            identifier: "SidebarAccountSignOutButton"
        ) {
            Task { await flow?.signOut() }
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
                Text(displayName.isEmpty ? email : displayName)
                    .cmuxFont(size: 13, weight: .semibold)
                    .lineLimit(1)
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
