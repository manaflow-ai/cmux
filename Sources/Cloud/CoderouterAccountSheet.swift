import CmuxCloud
import SwiftUI

/// Native account intake for the CodeRouter team pool. Secrets stay in local
/// form state long enough to submit, then are released with the sheet.
struct CoderouterAccountSheet: View {
    enum AccountKind: String, CaseIterable, Identifiable {
        case oauth = "Claude OAuth token"
        case apiKey = "Anthropic API key"
        case bedrock = "Amazon Bedrock"
        var id: String { rawValue }
    }

    let teamID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AccountKind = .oauth
    @State private var label = ""
    @State private var secret = ""
    @State private var region = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add CodeRouter account").font(.title2.weight(.semibold))
            Text(teamID.map { "This account will be added to the selected team (\($0))." } ?? "Select a team before adding an account.")
                .foregroundStyle(.secondary)
            Picker("Account type", selection: $kind) {
                ForEach(AccountKind.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Label (optional)", text: $label)
            if kind == .oauth || kind == .apiKey {
                SecureField(kind == .oauth ? "OAuth token" : "API key", text: $secret)
            } else {
                TextField("AWS region", text: $region)
                TextField("Access key ID", text: $accessKeyID)
                SecureField("Secret access key", text: $secretAccessKey)
                SecureField("Session token (optional)", text: $sessionToken)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add account") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || teamID?.isEmpty != false || !isValid)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var isValid: Bool {
        switch kind {
        case .oauth, .apiKey: !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bedrock: !region.isEmpty && !accessKeyID.isEmpty && !secretAccessKey.isEmpty
        }
    }

    private func save() {
        guard let teamID, !teamID.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        let input: ClaudeUpstreamInput
        switch kind {
        case .oauth: input = .anthropicOAuth(token: secret)
        case .apiKey: input = .anthropicAPIKey(secret)
        case .bedrock: input = .bedrock(region: region, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken.isEmpty ? nil : sessionToken, modelIDs: [:])
        }
        Task { @MainActor in
            do {
                _ = try await CoderouterClient.shared.addClaudeAccount(input, label: label.isEmpty ? nil : label, teamID: teamID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
