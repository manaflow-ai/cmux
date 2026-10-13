/// The person's password manager settings for Chromium (`browser.passwords.*`):
/// whether a tab asks to save a submitted sign-in (`CEFPasswordPrompts`), and
/// generated passwords without a Google account (fork API 20). Applied when
/// Chromium is ready and on each change.
enum CEFPasswordPolicy {
    private(set) static var offerToSave = true
    private static var generate = true

    static func set(offerToSave: Bool, generate: Bool) {
        self.offerToSave = offerToSave
        self.generate = generate
        apply()
    }

    static func apply() {
        let runtime = CEFRuntime.shared
        guard runtime.state == .ready, let shim = runtime.shim else { return }
        // Chrome's "Offer to save" off turns generation off too: a generated password would be saved unasked.
        _ = shim.setPasswordGenerationEnabled(generate && offerToSave ? 1 : 0)
    }
}

extension CEFEngine {
    /// Applies `browser.passwords.offerToSave` and `.generate` (process-wide).
    public func setPasswordPolicy(offerToSave: Bool, generate: Bool) {
        CEFPasswordPolicy.set(offerToSave: offerToSave, generate: generate)
    }
}
