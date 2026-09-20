import AppKit
import CmuxAppKitSupportUI
import CmuxSettingsUI
import SwiftUI

extension Notification.Name {
    static let cmuxTeamPickerShortcutRequested = Notification.Name("cmux.teamPicker.shortcutRequested")
}

/// The existing compact sidebar account button with team management added to
/// its account popover.
struct SidebarAccountMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private let title = String(localized: "settings.section.account", defaultValue: "Account")
    private let signInTitle = String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    @State private var isPopoverPresented = false
    @State private var isShowingTeamPicker = false
    @State private var popoverGroup = CmuxPopoverGroup()
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
            group: popoverGroup
        ) {
            SidebarAccountPopover(
                accountFlow: accountFlow,
                dismiss: { popoverGroup.dismissAll() },
                isShowingTeamPicker: $isShowingTeamPicker,
                popoverGroup: popoverGroup
            )
        })
        .safeHelp(buttonTitle)
        .accessibilityLabel(buttonTitle)
        .accessibilityIdentifier("SidebarAccountMenuButton")
        .task {
            for await _ in NotificationCenter.default.notifications(named: .cmuxTeamPickerShortcutRequested) {
                guard !Task.isCancelled else { return }
                isPopoverPresented = true
            }
        }
        .onChange(of: isPopoverPresented) { _, presented in
            if !presented {
                isShowingTeamPicker = false
            }
        }
    }
}

private struct SidebarAccountPopover: View {
    let accountFlow: HostAccountFlow?
    let dismiss: () -> Void
    @Binding var isShowingTeamPicker: Bool
    let popoverGroup: CmuxPopoverGroup
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared
    private let menuRowHeight: CGFloat = 28

    private var settingsShortcutHint: String {
        let _ = shortcutObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openSettings).displayString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Divider()
                if let accountFlow {
                    SidebarAccountTeamPickerRow(
                        accountFlow: accountFlow,
                        isPresented: $isShowingTeamPicker,
                        popoverGroup: popoverGroup
                    )
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
                }
                accountMenuRow(
                    title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                    systemImage: "sparkles"
                ) {
                    dismiss()
                    accountFlow?.openProUpgrade(source: .sidebarAccountMenu)
                }
                .accessibilityIdentifier("SidebarAccountUpgradeButton")
                .onHover { if $0 { isShowingTeamPicker = false } }
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
                .onHover { if $0 { isShowingTeamPicker = false } }
            }
        }
        .buttonStyle(.plain)
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .padding(12)
        .frame(width: 220, alignment: .leading)
    }

    private var settingsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
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
                .frame(minHeight: menuRowHeight, alignment: .leading)
            }
            .accessibilityLabel(String(
                format: String(localized: "sidebar.account.settingsLabel", defaultValue: "%1$@, %2$@"),
                String(localized: "menu.app.settings", defaultValue: "Settings…"),
                settingsShortcutHint
            ))
            .accessibilityIdentifier("SidebarAccountSettingsButton")
            .onHover { if $0 { isShowingTeamPicker = false } }
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
                .frame(minHeight: menuRowHeight, alignment: .leading)
        }
    }
}
