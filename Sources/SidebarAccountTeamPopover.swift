import AppKit
import CmuxSettingsUI
import SwiftUI

extension Notification.Name {
    static let cmuxTeamPickerShortcutRequested = Notification.Name("cmux.teamPicker.shortcutRequested")
}

/// The sidebar account button and its team-aware account popover.
struct SidebarAccountMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    private var accountFlow: HostAccountFlow? { AppDelegate.shared?.auth?.accountFlow }
    private let title = String(localized: "settings.section.account", defaultValue: "Account")
    private let signInTitle = String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    @State private var isPopoverPresented = false
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        let identity = accountFlow?.currentIdentity
        let isSignedIn = identity != nil
        let buttonTitle = isSignedIn ? title : signInTitle
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
            HStack(spacing: 8) {
                SidebarAccountPopoverAvatar(
                    identity: identity,
                    size: isSignedIn ? 28 : buttonSize
                )
                if isSignedIn, let accountFlow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity?.displayName.isEmpty == false ? identity?.displayName ?? "" : identity?.email ?? "")
                            .cmuxFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                        Text(accountFlow.sidebarTeamSubtitle)
                            .cmuxFont(size: 10)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 132, alignment: .leading)
                }
            }
            .frame(minWidth: isSignedIn ? 168 : buttonSize, minHeight: 32, alignment: .leading)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .disabled(accountFlow?.isWorkingOnAuth == true)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SidebarAccountPopover(
                accountFlow: accountFlow,
                dismiss: { isPopoverPresented = false }
            )
        })
        .safeHelp(buttonTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(buttonTitle)
        .accessibilityIdentifier("SidebarAccountMenuButton")
        .task {
            for await _ in NotificationCenter.default.notifications(named: .cmuxTeamPickerShortcutRequested) {
                guard !Task.isCancelled else { return }
                isPopoverPresented = true
            }
        }
        .onChange(of: shortcutObserver.revision) { _, _ in
            // Keep the shortcut observer alive while the button is mounted so
            // the Settings hint in the popover updates without reopening it.
        }
    }
}

private struct SidebarAccountPopover: View {
    let accountFlow: HostAccountFlow?
    let dismiss: () -> Void
    @State private var isCreatingTeam = false
    @State private var newTeamName = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    private var settingsShortcutHint: String {
        let _ = shortcutObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openSettings).displayString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            Divider()
            if let accountFlow, accountFlow.availableTeams.isEmpty {
                Text(String(localized: "sidebar.account.loadingTeams", defaultValue: "Loading teams…"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            } else if let accountFlow {
                ForEach(accountFlow.availableTeams) { team in
                    teamRow(team, isSelected: team.id == accountFlow.coordinator.resolvedTeamID)
                }
            }
            if isCreatingTeam {
                createTeamEditor
            } else {
                popoverRow(
                    title: String(localized: "sidebar.account.createTeam", defaultValue: "Create team…"),
                    systemImage: "plus"
                ) {
                    errorMessage = nil
                    newTeamName = ""
                    isCreatingTeam = true
                }
                .accessibilityIdentifier("SidebarAccountCreateTeamButton")
            }
            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(errorMessage)
            }
            Divider()
            popoverRow(
                title: String(localized: "menu.app.settings", defaultValue: "Settings…"),
                systemImage: "gearshape",
                trailing: settingsShortcutHint
            ) {
                dismiss()
                AppDelegate.shared?.openPreferencesWindow(
                    debugSource: "sidebar.account.settings",
                    navigationTarget: .account
                )
            }
            .accessibilityIdentifier("SidebarAccountSettingsButton")
            if accountFlow?.isProUpgradeAvailable == true {
                popoverRow(
                    title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                    systemImage: "sparkles"
                ) {
                    dismiss()
                    accountFlow?.openProUpgrade(source: .sidebarAccountMenu)
                }
                .accessibilityIdentifier("SidebarAccountUpgradeButton")
            }
            if accountFlow?.currentIdentity != nil {
                popoverRow(
                    title: String(localized: "settings.account.signOut", defaultValue: "Sign Out"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    dismiss()
                    Task { await accountFlow?.signOut() }
                }
                .accessibilityIdentifier("SidebarAccountSignOutButton")
            }
        }
        .buttonStyle(.plain)
        .disabled(accountFlow?.isWorkingOnAuth == true || isSubmitting)
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    @ViewBuilder
    private var header: some View {
        if let identity = accountFlow?.currentIdentity {
            HStack(spacing: 10) {
                SidebarAccountPopoverAvatar(identity: identity, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName.isEmpty ? identity.email : identity.displayName)
                        .cmuxFont(size: 13, weight: .semibold)
                        .lineLimit(1)
                    if let accountFlow {
                        Text(accountFlow.sidebarTeamSubtitle)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(
                format: String(localized: "sidebar.account.headerLabel", defaultValue: "%1$@, %2$@"),
                identity.displayName.isEmpty ? identity.email : identity.displayName,
                accountFlow?.sidebarTeamSubtitle ?? ""
            ))
        } else {
            Text(String(localized: "settings.account.signedOut.title", defaultValue: "Not signed in"))
                .cmuxFont(size: 13, weight: .semibold)
        }
    }

    private func teamRow(_ team: AccountTeamSummary, isSelected: Bool) -> some View {
        popoverRow(
            title: team.displayName,
            systemImage: "person.2",
            trailing: isSelected ? "checkmark" : nil
        ) {
            guard !isSelected else { return }
            Task { @MainActor in
                do {
                    try await accountFlow?.selectTeam(id: team.id)
                    dismiss()
                } catch {
                    errorMessage = String(
                        localized: "sidebar.account.switchTeamFailed",
                        defaultValue: "Could not switch teams. Try again."
                    )
                }
            }
        }
        .accessibilityLabel(String(
            format: String(localized: "sidebar.account.teamRowLabel", defaultValue: "%1$@%2$@"),
            team.displayName,
            isSelected ? String(localized: "sidebar.account.activeSuffix", defaultValue: ", active") : ""
        ))
        .accessibilityIdentifier("SidebarAccountTeam_\(team.id)")
    }

    private var createTeamEditor: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "sidebar.account.createTeamPlaceholder", defaultValue: "Team name"),
                text: $newTeamName
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitCreateTeam() }
            Button {
                submitCreateTeam()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .disabled(newTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(String(localized: "sidebar.account.createTeamSubmit", defaultValue: "Create team"))
            Button {
                isCreatingTeam = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "sidebar.account.createTeamCancel", defaultValue: "Cancel"))
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("SidebarAccountCreateTeamEditor")
    }

    private func submitCreateTeam() {
        let name = newTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await accountFlow?.createTeam(displayName: name)
                isCreatingTeam = false
                newTeamName = ""
                dismiss()
            } catch {
                errorMessage = String(
                    localized: "sidebar.account.createTeamFailed",
                    defaultValue: "Could not create that team. Try again."
                )
            }
        }
    }

    private func popoverRow(
        title: String,
        systemImage: String,
        trailing: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        SidebarAccountPopoverRow(
            title: title,
            systemImage: systemImage,
            trailing: trailing,
            action: action
        )
    }
}

private struct SidebarAccountPopoverRow: View {
    let title: String
    let systemImage: String
    let trailing: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                    .cmuxFont(size: 12)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    if trailing == "checkmark" {
                        Image(systemName: trailing)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(trailing)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarAccountPopoverAvatar: View {
    let identity: AccountIdentity?
    let size: CGFloat

    var body: some View {
        if let identity {
            if identity.avatarURL != nil {
                SidebarAccountAvatar(
                    avatarURL: identity.avatarURL,
                    displayName: identity.displayName,
                    email: identity.email,
                    isSignedIn: true,
                    size: size
                )
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Text(initials(for: identity))
                        .cmuxFont(size: max(9, size * 0.38), weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        } else {
            SidebarAccountAvatar(
                avatarURL: nil,
                displayName: "",
                email: "",
                isSignedIn: false,
                size: size
            )
        }
    }

    private func initials(for identity: AccountIdentity) -> String {
        let source = identity.displayName.isEmpty ? identity.email : identity.displayName
        let words = source.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.count > 1 {
            return String(words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
        }
        return String(source.prefix(2)).uppercased()
    }
}
