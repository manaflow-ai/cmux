import LocalAuthentication

/// An `LAContext` that refuses user interaction, so a Keychain query never prompts.
enum NoPromptContext {
    static func make() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
