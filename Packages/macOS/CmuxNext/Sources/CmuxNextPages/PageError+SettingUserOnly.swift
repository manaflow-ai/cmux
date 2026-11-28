public import CmuxNextSettings

extension PageError {
    /// A write of a user-only setting by a writer that is not the person (``SettingUserOnly``), as a page answers it.
    public static func userOnly(_ refusal: SettingUserOnly) -> PageError {
        PageError(code: "cmux.settings.user_only", message: String(describing: refusal), details: ["key": .string(refusal.key)])
    }
}
