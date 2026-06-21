#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

/// The left-edge nav drawer: signed-in account header, the user's Stack teams
/// (tap to switch, current one checked), Settings, and Sign out.
///
/// Switching teams only writes `AuthCoordinator.selectedTeamID`; the root view
/// observes that one property and re-scopes the team-bound services lazily, so the
/// drawer never touches the shell store directly (one shared mutation path).
///
/// The team rows are driven by a value snapshot of the coordinator's state taken
/// in `body` (not read live inside the `ForEach`), so no `@Observable` store
/// crosses the inner `List`'s row boundary.
struct MobileNavDrawerView: View {
    @Environment(AuthCoordinator.self) private var authManager
    /// Open the Settings sheet (the caller owns the sheet at the shell level).
    let onSettings: () -> Void
    /// Sign out (the shell's existing sign-out path).
    let onSignOut: () -> Void
    /// Close the drawer.
    let onClose: () -> Void

    var body: some View {
        // Snapshot the observable auth state ONCE here; rows below use these values
        // + closures only.
        let teams = authManager.availableTeams
        let resolvedTeamID = authManager.resolvedTeamID
        let displayName = accountDisplayName
        let email = authManager.currentUser?.primaryEmail

        VStack(spacing: 0) {
            accountHeader(displayName: displayName, email: email)
            Divider()
            List {
                if teams.count > 1 {
                    Section {
                        ForEach(teams) { team in
                            teamRow(
                                id: team.id, displayName: team.displayName,
                                isCurrent: team.id == resolvedTeamID)
                        }
                    } header: {
                        Text(L10n.string("mobile.drawer.teams", defaultValue: "Teams"))
                    }
                }
                Section {
                    Button {
                        onClose()
                        onSettings()
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.settings", defaultValue: "Settings"),
                            systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("MobileDrawerSettings")
                    Button(role: .destructive) {
                        onClose()
                        onSignOut()
                    } label: {
                        Label(
                            L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                            systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("MobileDrawerSignOut")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .accessibilityIdentifier("MobileNavDrawer")
    }

    private func teamRow(id: String, displayName: String, isCurrent: Bool) -> some View {
        Button {
            // Single shared mutation path: just select the team; the root view's
            // onChange does the lazy re-scope. No-op when it's already current.
            if !isCurrent {
                authManager.selectedTeamID = id
            }
            onClose()
        } label: {
            HStack {
                Text(displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(
                            L10n.string("mobile.drawer.currentTeam", defaultValue: "Current team"))
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func accountHeader(displayName: String, email: String?) -> some View {
        HStack(spacing: 12) {
            Text(initials(from: displayName))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountDisplayName: String {
        let user = authManager.currentUser
        if let name = user?.displayName, !name.isEmpty { return name }
        if let email = user?.primaryEmail, !email.isEmpty { return email }
        return L10n.string("mobile.drawer.account", defaultValue: "Account")
    }

    private func initials(from name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        guard let first = parts.first?.first else { return "?" }
        if parts.count > 1, let second = parts.dropFirst().first?.first {
            return String([first, second]).uppercased()
        }
        return String(first).uppercased()
    }
}

#endif
