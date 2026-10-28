import CmuxNextCodeRouter
import CmuxNextDesign
import SwiftUI

/// The inline paste field for a key or a Claude setup-token. A secure
/// field: the value is never shown, logged or kept after the action. Keys
/// go to the Keychain or to CodeRouter; a Claude token only to CodeRouter.
struct PasteField: View {
    let model: AccountsModel
    let provider: AIProvider
    let palette: AccountsPalette
    @State private var secret = ""
    @State private var error: String?
    /// A Keychain save is in flight: Save is off until it answers.
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text(provider == .claude ? AccountsStrings.pasteClaudeTitle : AccountsStrings.pasteKeyTitle(provider.displayName))
                .font(palette.emphasized)
            Text(provider == .claude ? AccountsStrings.pasteClaudeBody : AccountsStrings.pasteKeyBody)
                .font(palette.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            ThemedField(text: $secret, placeholder: AccountsStrings.pastePlaceholder, secure: true,
                        identifier: "cmux.accounts.paste.\(provider.rawValue)")
            if let error { Text(error).font(palette.caption).foregroundStyle(palette.danger) }
            HStack(spacing: Metrics.space3) {
                if provider == .claude {
                    Button(AccountsStrings.runSetupToken) { model.services.runClaudeSetupToken() }
                }
                if provider.acceptsPastedKey {
                    Button(AccountsStrings.saveToKeychain) {
                        let value = secret
                        saving = true
                        // The Keychain write runs off the main thread; the field stays until it answers.
                        model.saveKey(value, for: provider) { failure in
                            saving = false
                            if let failure { error = failure } else { close() }
                        }
                    }
                    .disabled(secret.isEmpty || saving)
                }
                if provider.codeRouterLink != .unsupported {
                    Button(AccountsStrings.sendToCodeRouter) {
                        let value = secret
                        close()
                        model.connect(provider, pasted: value)
                    }
                    .disabled(secret.isEmpty || !model.isSignedInToCmux)
                }
                Spacer(minLength: 0)
                Button(AccountsStrings.cancel) { close() }
            }
            .buttonStyle(AccountsButtonStyle(palette: palette))
        }
        .padding(Metrics.space4)
        .background(palette.hover, in: RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous))
    }

    private func close() {
        secret = ""
        error = nil
        model.pasteTarget = nil
    }
}
