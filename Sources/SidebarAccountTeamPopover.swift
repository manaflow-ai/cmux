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

/// The sidebar account chip for account-level actions. Signed out,
/// a click starts sign-in; signed in, it opens a native account menu (see
/// `SidebarFooterMenuAnchor` for why the footer uses `NSMenu`).
struct SidebarAccountMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private let title = String(localized: "settings.section.account", defaultValue: "Account")
    private let signInTitle = String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    /// False when the footer is too narrow for the name: avatar and chevron.
    var showsName = true
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
            // The chip fills the footer's free width and all of it is the
            // target, like the account row in Claude and ChatGPT desktop. The
            // chevron at the trailing edge marks where the target ends and says
            // it opens a menu. When the footer is too narrow for the name,
            // `SidebarFooterButtons` drops to avatar and chevron. Signed out it
            // reads "Sign In…" with no chevron.
            HStack(spacing: 5) {
                SidebarAccountAvatar(
                    avatarURL: identity?.avatarURL,
                    displayName: identity?.displayName ?? "",
                    email: identity?.email ?? "",
                    isSignedIn: profile.showsProfilePicture,
                    size: profile.showsProfilePicture ? SidebarAccountChipMetrics.avatarSize : profile.size
                )
                .frame(width: SidebarAccountChipMetrics.avatarSize, height: SidebarAccountChipMetrics.avatarSize)
                if showsName || identity == nil {
                    Text(chipName(for: identity) ?? signInTitle)
                        .cmuxFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Ideal width is a floor, not the whole name, so the
                        // footer keeps the name (truncated) down to a short
                        // stub before it falls back to avatar and chevron.
                        .frame(idealWidth: SidebarAccountChipMetrics.minNameWidth, maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                if identity != nil {
                    CmuxSystemSymbolImage(
                        systemName: "chevron.up.chevron.down",
                        pointSize: SidebarAccountChipMetrics.chevronPointSize,
                        weight: .medium,
                        tint: Color(nsColor: .secondaryLabelColor)
                    )
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, minHeight: SidebarAccountChipMetrics.height, maxHeight: SidebarAccountChipMetrics.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SidebarFooterMenuAnchorView(anchor: menuAnchor))
        .safeHelp(buttonTitle)
        .accessibilityLabel(buttonTitle)
        .accessibilityValue(chipName(for: identity) ?? "")
        .accessibilityIdentifier("SidebarAccountMenuButton")
    }

    private func chipName(for identity: AccountIdentity?) -> String? {
        guard let identity else { return nil }
        return identity.displayName.isEmpty ? identity.email : identity.displayName
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
            email: email,
            isPro: flow?.isProActive == true
        ))
        headerView.frame.size = headerView.fittingSize
        headerView.autoresizingMask = [.width]
        header.view = headerView
        menu.addItem(header)
        menu.addSidebarFooterSeparator()

        menu.addSidebarFooterItem(
            String(localized: "menu.app.settings", defaultValue: "Settings…"),
            identifier: "SidebarAccountSettingsButton",
            shortcut: KeyboardShortcutSettings.menuShortcut(for: .openSettings)
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
