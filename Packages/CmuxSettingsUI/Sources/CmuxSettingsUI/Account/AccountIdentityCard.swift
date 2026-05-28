import CmuxSettings
import SwiftUI

/// Compact identity card rendered at the top of the Account section.
///
/// Pulls the current user from the supplied ``AccountFlow``. Hides
/// PII (display name + email) when ``piiModel`` resolves to
/// ``PIIDisplayMode/hidden`` — typical when the user is recording a
/// screen for support. The card still renders the avatar so the user
/// can confirm they are signed into the right identity.
@MainActor
struct AccountIdentityCard: View {
    let flow: AccountFlow?
    @State var piiModel: DefaultsValueModel<PIIDisplayMode>

    init(flow: AccountFlow?, piiModel: DefaultsValueModel<PIIDisplayMode>) {
        self.flow = flow
        _piiModel = State(initialValue: piiModel)
    }

    var body: some View {
        if let flow {
            HStack(spacing: 12) {
                avatar(for: flow)
                identityLines(for: flow)
                Spacer()
                actionsCluster(for: flow)
            }
        } else {
            HStack(spacing: 12) {
                avatarPlaceholder
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign-in not available")
                        .font(.headline)
                    Text("This build doesn't expose a sign-in flow to the settings UI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func avatar(for flow: AccountFlow) -> some View {
        if let url = flow.currentIdentity?.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: avatarPlaceholder
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                case .failure: avatarPlaceholder
                @unknown default: avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 44, height: 44)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func identityLines(for flow: AccountFlow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let identity = flow.currentIdentity {
                Text(redact(identity.displayName.isEmpty ? identity.email : identity.displayName))
                    .font(.headline)
                Text(redact(identity.email))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not signed in")
                    .font(.headline)
                Text("Sign in to sync your settings, teams, and agent sessions across devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionsCluster(for flow: AccountFlow) -> some View {
        if flow.isWorkingOnAuth {
            ProgressView()
                .controlSize(.small)
        } else if flow.currentIdentity != nil {
            HStack(spacing: 6) {
                Button("Refresh") {
                    Task { await flow.refreshCurrentUser() }
                }
                .buttonStyle(.bordered)
                Button("Sign Out", role: .destructive) {
                    Task { await flow.signOut() }
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button("Sign In…") {
                flow.startSignIn()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func redact(_ value: String) -> String {
        switch piiModel.current {
        case .visible: return value
        case .hidden: return value.isEmpty ? value : "••••••••"
        }
    }
}
