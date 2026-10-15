import CmuxCloud
import CmuxFoundation
import SwiftUI

/// "Open Repository in Cloud…": one field, an optional agent and first task, the git
/// auth offer when it matters, the exact command it will run, and one primary button.
struct CloudOpenRepositorySheet: View {
    @Bindable var model: CloudOpenRepositorySheetModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case repository, prompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "cloudOpenRepository.title", defaultValue: "Open Repository in Cloud"))
                    .cmuxFont(size: 15, weight: .semibold)
                Text(String(
                    localized: "cloudOpenRepository.subtitle",
                    defaultValue: "Clones it on a Cloud machine and opens a workspace in the checkout."
                ))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            repositoryField
            agentRow
            if model.showsGitHubTokenOffer { tokenOffer }
            commandPreview
            if let error = model.runError {
                Text(error)
                    .cmuxFont(size: 11)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CloudOpenRepositorySheet.runError")
            }
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focusedField = .repository }
        .accessibilityIdentifier("CloudOpenRepositorySheet")
    }

    private var repositoryField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                String(localized: "cloudOpenRepository.field.placeholder", defaultValue: "github.com/owner/repo or owner/repo"),
                text: $model.repositoryText
            )
            .textFieldStyle(.roundedBorder)
            .cmuxFont(size: 13, design: .monospaced)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .repository)
            .onSubmit { model.run() }
            .accessibilityLabel(String(localized: "cloudOpenRepository.field.label", defaultValue: "Repository"))
            .accessibilityIdentifier("CloudOpenRepositorySheet.repository")

            if let message = model.validationMessage {
                Text(message)
                    .cmuxFont(size: 11)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CloudOpenRepositorySheet.validation")
            } else if let reference = model.reference {
                Text(Self.summary(reference))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("CloudOpenRepositorySheet.summary")
            }
        }
    }

    private var agentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "cloudOpenRepository.agent.label", defaultValue: "Agent"), selection: $model.agent) {
                Text(String(localized: "cloudOpenRepository.agent.none", defaultValue: "None"))
                    .tag(CloudOpenRepositorySheetModel.Agent?.none)
                ForEach(CloudOpenRepositorySheetModel.Agent.allCases, id: \.self) { agent in
                    Text(agent.displayName).tag(CloudOpenRepositorySheetModel.Agent?.some(agent))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .cmuxFont(size: 12)
            .accessibilityIdentifier("CloudOpenRepositorySheet.agent")

            if model.agent != nil {
                TextField(
                    String(
                        localized: "cloudOpenRepository.prompt.placeholder",
                        defaultValue: "First task (optional), e.g. run the tests and fix failures"
                    ),
                    text: $model.prompt
                )
                .textFieldStyle(.roundedBorder)
                .cmuxFont(size: 12)
                .focused($focusedField, equals: .prompt)
                .onSubmit { model.run() }
                .accessibilityIdentifier("CloudOpenRepositorySheet.prompt")
                Text(String(
                    localized: "cloudOpenRepository.prompt.note",
                    defaultValue: "With a task the agent runs it once; leave it empty to start an interactive session."
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown only for a GitHub repository with no token in Cloud Secrets. Public
    /// repositories clone without one, so it is an offer beside the form, not a gate.
    private var tokenOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.tokenState {
            case .stored:
                Label(
                    String(
                        localized: "cloudOpenRepository.token.stored",
                        defaultValue: "GH_TOKEN saved to Cloud Secrets for every machine."
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("CloudOpenRepositorySheet.tokenStored")
            default:
                Text(String(
                    localized: "cloudOpenRepository.token.missing",
                    defaultValue: "Cloud Secrets has no GitHub token. Public repositories clone without one; a private one needs it."
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = model.tokenState {
                    Text(message)
                        .cmuxFont(size: 11)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .cloudErrorCopyMenu(message)
                        .accessibilityIdentifier("CloudOpenRepositorySheet.tokenError")
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.useGitHubCLILogin() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.tokenState == .readingGitHubCLI {
                                ProgressView().controlSize(.small)
                            }
                            Text(String(localized: "cloudOpenRepository.token.useGH", defaultValue: "Use My GitHub CLI Login"))
                        }
                    }
                    .disabled(model.tokenState == .readingGitHubCLI)
                    .help(String(
                        localized: "cloudOpenRepository.token.useGH.help",
                        defaultValue: "Reads `gh auth token` and stores it as GH_TOKEN. The token is never shown or logged."
                    ))
                    .accessibilityIdentifier("CloudOpenRepositorySheet.useGH")
                    Button(String(localized: "cloudOpenRepository.token.openSecrets", defaultValue: "Cloud Secrets…")) {
                        model.openSecrets()
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("CloudOpenRepositorySheet.openSecrets")
                }
                .cmuxFont(size: 12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudOpenRepositorySheet.tokenOffer")
    }

    /// The exact command, so what runs is never a surprise and can be typed again.
    @ViewBuilder
    private var commandPreview: some View {
        if let command = model.command {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "cloudOpenRepository.preview.label", defaultValue: "Runs in a new terminal:"))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                Text(command.displayLine)
                    .cmuxFont(size: 11, design: .monospaced)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .help(command.displayLine)
                    .accessibilityIdentifier("CloudOpenRepositorySheet.command")
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) { model.cancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("CloudOpenRepositorySheet.cancel")
            Button(String(localized: "cloudOpenRepository.run", defaultValue: "Open in Cloud")) { model.run() }
                .disabled(!model.canRun)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("CloudOpenRepositorySheet.run")
        }
        .padding(.top, 4)
    }

    static func summary(_ reference: CloudOpenRepositoryReference) -> String {
        if let branch = reference.branch {
            return String(
                format: String(localized: "cloudOpenRepository.summary.branch", defaultValue: "%1$@ · branch %2$@"),
                reference.projectKey, branch
            )
        }
        return String(
            format: String(localized: "cloudOpenRepository.summary.default", defaultValue: "%@ · default branch"),
            reference.projectKey
        )
    }
}
