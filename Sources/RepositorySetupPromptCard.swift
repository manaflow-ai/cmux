import SwiftUI

struct RepositorySetupPromptCard: View {
    let prompt: RepositorySetupPrompt
    let showsDismissError: Bool
    let onConfigure: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "repositorySetup.prompt.title", defaultValue: "Automate repository setup"))
                    .font(.headline)
                Text(String(
                    localized: "repositorySetup.prompt.message",
                    defaultValue: "Add a setup script for this repository so new workspaces are ready automatically."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if showsDismissError {
                    Text(String(
                        localized: "repositorySetup.prompt.dismissFailed",
                        defaultValue: "Couldn't save this preference."
                    ))
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            Button(String(localized: "repositorySetup.prompt.configure", defaultValue: "Configure"), action: onConfigure)
                .buttonStyle(.borderedProminent)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(String(localized: "repositorySetup.prompt.dismiss", defaultValue: "Don't show again for this repository"))
            .accessibilityLabel(String(
                localized: "repositorySetup.prompt.dismiss",
                defaultValue: "Don't show again for this repository"
            ))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .padding(12)
    }
}
