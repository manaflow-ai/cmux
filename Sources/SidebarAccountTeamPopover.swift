import AppKit
import CmuxAppKitSupportUI
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// The compact sidebar account button for account-level actions.
struct SidebarAccountMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private let title = String(localized: "settings.section.account", defaultValue: "Account")
    private let signInTitle = String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    @Environment(\.cmuxInterfaceDensity) private var density
    private var buttonSize: CGFloat { SidebarFooterButtonMetrics.buttonSize(for: density) }
    /// The sidebar footer owns this so compact density can keep the button
    /// visible while its popover is open; the pointer is inside the popover by
    /// then, so footer hover has already ended.
    @Binding var isPopoverPresented: Bool
    @State private var popoverGroup = CmuxPopoverGroup()

    init(isPopoverPresented: Binding<Bool>) {
        _isPopoverPresented = isPopoverPresented
    }
#if DEBUG
    @AppStorage(SidebarFooterProfileIconDebugSettings.sizeKey)
    private var debugIconSize = SidebarFooterProfileIconDebugSettings.defaultSize
    @AppStorage(SidebarFooterProfileDisplayDebugSettings.displayKey)
    private var debugProfileDisplay = SidebarFooterProfileDisplayDebugSettings.defaultDisplay.rawValue
#endif

    private var profileIconSize: CGFloat {
#if DEBUG
        if let override = SidebarFooterButtonMetrics.debugOverride(
            key: SidebarFooterProfileIconDebugSettings.sizeKey,
            value: debugIconSize
        ) {
            return override
        }
#endif
        return SidebarFooterButtonMetrics.primaryIconSize(for: density)
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
            hasProfilePicture: hasProfilePicture,
            density: density
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
            if isSignedIn {
                isPopoverPresented.toggle()
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
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4,
            presentationAnimation: .enabled,
            group: popoverGroup
        ) {
            SidebarAccountPopover(
                accountFlow: accountFlow,
                dismiss: { popoverGroup.dismissAll() }
            )
        })
        .safeHelp(buttonTitle)
        .accessibilityLabel(buttonTitle)
        .accessibilityIdentifier("SidebarAccountMenuButton")
    }
}

private struct SidebarAccountPopover: View {
    let accountFlow: HostAccountFlow?
    let dismiss: () -> Void
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    private var settingsShortcutHint: String {
        let _ = shortcutObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openSettings).displayString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let identity = accountFlow?.currentIdentity {
                HStack(spacing: 10) {
                    SidebarAccountAvatar(
                        avatarURL: identity.avatarURL,
                        displayName: identity.displayName,
                        email: identity.email,
                        isSignedIn: true,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.displayName.isEmpty ? identity.email : identity.displayName)
                            .cmuxFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                        if !identity.email.isEmpty && identity.email != identity.displayName {
                            Text(identity.email)
                                .cmuxFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                settingsRow
            } else {
                Text(String(localized: "settings.account.signedOut.title", defaultValue: "Not signed in"))
                    .cmuxFont(size: 13, weight: .semibold)
                Button {
                    dismiss()
                    accountFlow?.startSignIn()
                } label: {
                    Label(
                        String(localized: "settings.account.signIn", defaultValue: "Sign In…"),
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("SidebarAccountSignInButton")
            }
            if accountFlow?.isProUpgradeAvailable == true {
                if accountFlow?.currentIdentity == nil {
                    Divider()
                        .padding(.vertical, 4)
                }
                accountMenuRow(
                    title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                    systemImage: "sparkles"
                ) {
                    dismiss()
                    accountFlow?.openProUpgrade(source: .sidebarAccountMenu)
                }
                .accessibilityIdentifier("SidebarAccountUpgradeButton")
            }
            if accountFlow?.currentIdentity != nil {
                accountMenuRow(
                    title: String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    dismiss()
                    Task { await accountFlow?.signOut() }
                }
                .accessibilityIdentifier("SidebarAccountSignOutButton")
            }
        }
        .buttonStyle(SidebarAccountMenuButtonStyle())
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .padding(12)
        .frame(width: 220, alignment: .leading)
    }

    private var settingsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.vertical, 4)
            Button {
                dismiss()
                AppDelegate.shared?.openPreferencesWindow(
                    debugSource: "sidebar.account.settings",
                    navigationTarget: .account
                )
            } label: {
                HStack(spacing: 8) {
                    Label(
                        String(localized: "menu.app.settings", defaultValue: "Settings…"),
                        systemImage: "gearshape"
                    )
                    Spacer(minLength: 8)
                    Text(settingsShortcutHint)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(String(
                format: String(localized: "sidebar.account.settingsLabel", defaultValue: "%1$@, %2$@"),
                String(localized: "menu.app.settings", defaultValue: "Settings…"),
                settingsShortcutHint
            ))
            .accessibilityIdentifier("SidebarAccountSettingsButton")
        }
    }


    private func accountMenuRow(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
