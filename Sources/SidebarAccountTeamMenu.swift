import CmuxSettingsUI
import SwiftUI

/// What the account popover's team section shows, decided without SwiftUI so
/// the rules are testable on their own.
///
/// The active team is supplied by the caller rather than re-derived here: the
/// app already resolves it once (an unknown or absent selection falls back to
/// the first team), and a second copy of that rule could disagree with the
/// team the app actually scopes cloud reads to.
struct AccountTeamMenuPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let displayName: String
        let isActive: Bool
    }

    /// One row per team the user belongs to, in backend order.
    let rows: [Row]
    /// Whether to render the team list and its divider at all.
    let showsTeamList: Bool
    /// Whether `Create team…` is offered.
    let showsCreateTeam: Bool
    /// The active team's name for the popover header, or `nil` when there is
    /// no active team to name.
    let activeTeamName: String?

    static let signedOut = AccountTeamMenuPresentation(
        rows: [],
        showsTeamList: false,
        showsCreateTeam: false,
        activeTeamName: nil
    )
}

enum AccountTeamMenuPresentationResolver {
    /// Builds the team section for one popover presentation.
    ///
    /// - Parameters:
    ///   - teams: The teams the signed-in user belongs to.
    ///   - activeTeamID: The team the app currently scopes to.
    ///   - isSignedIn: Whether an account is signed in.
    static func resolve(
        teams: [AccountTeamSummary],
        activeTeamID: String?,
        isSignedIn: Bool
    ) -> AccountTeamMenuPresentation {
        guard isSignedIn else { return .signedOut }
        let rows = teams.map { team in
            AccountTeamMenuPresentation.Row(
                id: team.id,
                displayName: team.displayName,
                isActive: team.id == activeTeamID
            )
        }
        return AccountTeamMenuPresentation(
            rows: rows,
            // A single team is still worth listing: it names the team every
            // cloud workspace in this window belongs to.
            showsTeamList: !rows.isEmpty,
            // Offered even with no teams yet, since creating the first team is
            // how a new account starts sharing cloud workspaces at all.
            showsCreateTeam: true,
            activeTeamName: rows.first(where: { $0.isActive })?.displayName
        )
    }
}

/// Whether a typed team name may be submitted.
enum AccountTeamNameValidator {
    static func isSubmittable(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The inline "Create team" form's state, owned by the account popover so
/// creating a team never takes the user out of the picker they opened.
@Observable
final class AccountTeamCreationState {
    /// Whether the form has replaced the team list.
    var isPresentingForm = false
    /// The name being typed.
    var name = ""
    /// Whether a create round trip is in flight.
    var isCreating = false
    /// The last failure's display text, cleared on the next attempt.
    var failureMessage: String?

    var canSubmit: Bool {
        !isCreating && AccountTeamNameValidator.isSubmittable(name)
    }

    func present() {
        name = ""
        failureMessage = nil
        isPresentingForm = true
    }

    func cancel() {
        isPresentingForm = false
        name = ""
        failureMessage = nil
    }
}

extension SidebarAccountPopover {
    /// The team list, or the create form while it is up.
    @ViewBuilder
    var teamSection: some View {
        if teamCreation.isPresentingForm {
            createTeamForm
        } else {
            teamList
        }
    }

    @ViewBuilder
    private var teamList: some View {
        if presentation.showsTeamList {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(presentation.rows) { row in
                    Button {
                        // Selecting the team already in use would churn every
                        // cloud scope for nothing.
                        guard !row.isActive else {
                            dismiss()
                            return
                        }
                        accountFlow?.selectedTeamID = row.id
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .cmuxFont(size: 11, weight: .semibold)
                                .opacity(row.isActive ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(row.displayName)
                                .cmuxFont(size: 13)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("SidebarAccountTeamRow")
                    .accessibilityLabel(row.displayName)
                    .accessibilityAddTraits(row.isActive ? [.isSelected] : [])
                }
            }
        }
        if presentation.showsCreateTeam {
            Button {
                teamCreation.present()
            } label: {
                Label(
                    String(localized: "sidebar.account.createTeam", defaultValue: "Create Team…"),
                    systemImage: "plus"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("SidebarAccountCreateTeamButton")
        }
    }

    @ViewBuilder
    private var createTeamForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "sidebar.account.createTeam.title", defaultValue: "New team"))
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "sidebar.account.createTeam.namePlaceholder", defaultValue: "Team name"),
                text: Binding(
                    get: { teamCreation.name },
                    set: { teamCreation.name = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .cmuxFont(size: 13)
            .disabled(teamCreation.isCreating)
            .onSubmit { submitCreateTeam() }
            .accessibilityIdentifier("SidebarAccountCreateTeamField")
            if let failure = teamCreation.failureMessage {
                Text(failure)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SidebarAccountCreateTeamError")
            }
            HStack(spacing: 8) {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    teamCreation.cancel()
                }
                .disabled(teamCreation.isCreating)
                .accessibilityIdentifier("SidebarAccountCreateTeamCancelButton")
                Button(String(localized: "sidebar.account.createTeam.confirm", defaultValue: "Create")) {
                    submitCreateTeam()
                }
                .disabled(!teamCreation.canSubmit)
                .accessibilityIdentifier("SidebarAccountCreateTeamConfirmButton")
            }
            .buttonStyle(.bordered)
            .cmuxFont(size: 12)
        }
    }

    private func submitCreateTeam() {
        guard teamCreation.canSubmit, let accountFlow else { return }
        let name = teamCreation.name
        teamCreation.isCreating = true
        teamCreation.failureMessage = nil
        Task { @MainActor in
            defer { teamCreation.isCreating = false }
            do {
                // The flow makes the created team active; closing the popover
                // on success is what shows the switch took effect.
                try await accountFlow.createTeam(named: name)
                teamCreation.cancel()
                dismiss()
            } catch {
                teamCreation.failureMessage = Self.failureText(for: error)
            }
        }
    }

    /// Team-creation failures are shown in place, not swallowed: a silent
    /// no-op here reads as "cmux is broken" and the user retypes the name.
    static func failureText(for error: any Error) -> String {
        let described = (error as? LocalizedError)?.errorDescription
        if let described, !described.isEmpty { return described }
        return String(
            localized: "sidebar.account.createTeam.failed",
            defaultValue: "Could not create the team. Try again."
        )
    }
}
