import Observation
import SwiftUI

/// Invitations the signed-in user received, above the Members card. Renders
/// nothing while there are none, so the page stays plain.
@MainActor
public struct AccountInvitationsCard: View {
    public static let searchAnchorID = "setting:account:invitations"

    @State private var model: AccountInvitationsCardModel

    public init(flow: AccountFlow) {
        _model = State(initialValue: AccountInvitationsCardModel(flow: flow))
    }

    public var body: some View {
        Group {
            if !model.invitations.isEmpty || model.errorMessage != nil {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(localized: "settings.invitations.title", defaultValue: "Invitations", bundle: .module))
                            .cmuxFont(size: 13, weight: .medium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if let message = model.errorMessage {
                            Divider()
                            Text(message)
                                .cmuxFont(size: 11)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("SettingsInvitationsError")
                        }
                        ForEach(model.invitations) { invitation in
                            Divider()
                            row(invitation)
                        }
                    }
                }
                .settingsSearchAnchors([Self.searchAnchorID])
            }
        }
        .onAppear { model.reload() }
        .accessibilityIdentifier("SettingsInvitationsCard")
    }

    private func row(_ invitation: AccountReceivedInvitation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invitation.teamName).cmuxFont(size: 13, weight: .medium).lineLimit(1)
                Text(subtitle(invitation)).cmuxFont(size: 11).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.pendingID == invitation.id {
                ProgressView().controlSize(.small)
            } else {
                Button(String(localized: "settings.invitations.ignore", defaultValue: "Ignore", bundle: .module)) {
                    model.decline(invitation)
                }
                .controlSize(.small)
                .disabled(model.pendingID != nil)
                Button(String(localized: "settings.invitations.join", defaultValue: "Join", bundle: .module)) {
                    model.accept(invitation)
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(model.pendingID != nil)
                .accessibilityIdentifier("SettingsInvitationJoin_\(invitation.id)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityIdentifier("SettingsInvitation_\(invitation.id)")
    }

    /// "Invited by Ada · Admin" or "Admin" when the inviter is unknown.
    private func subtitle(_ invitation: AccountReceivedInvitation) -> String {
        let role = invitation.role == .admin
            ? String(localized: "settings.team.role.admin", defaultValue: "Admin", bundle: .module)
            : String(localized: "settings.team.role.member", defaultValue: "Member", bundle: .module)
        guard let inviter = invitation.invitedBy, !inviter.isEmpty else { return role }
        return String.localizedStringWithFormat(
            String(localized: "settings.invitations.invitedBy", defaultValue: "Invited by %1$@ · %2$@", bundle: .module),
            inviter,
            role
        )
    }
}

@MainActor
@Observable
final class AccountInvitationsCardModel {
    private let flow: AccountFlow
    var invitations: [AccountReceivedInvitation] = []
    var errorMessage: String?
    var pendingID: String?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(flow: AccountFlow) {
        self.flow = flow
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await flow.loadReceivedInvitations()
                guard !Task.isCancelled else { return }
                invitations = loaded
            } catch is CancellationError {
            } catch {
                // A failed read shows nothing: an empty card is better than an
                // error for a list that is usually empty.
                invitations = []
            }
        }
    }

    func accept(_ invitation: AccountReceivedInvitation) {
        run(id: invitation.id) { [self] in try await flow.acceptReceivedInvitation(id: invitation.id) }
    }

    func decline(_ invitation: AccountReceivedInvitation) {
        run(id: invitation.id) { [self] in try await flow.declineReceivedInvitation(id: invitation.id) }
    }

    private func run(id: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard pendingID == nil else { return }
        pendingID = id
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action()
                invitations.removeAll { $0.id == id }
                pendingID = nil
                reload()
            } catch {
                pendingID = nil
                errorMessage = flow.teamManagementMessage(for: error)
            }
        }
    }
}
