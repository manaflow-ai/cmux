import CMUXAgentLaunch

extension CmuxVaultAgentRegistration {
    /// The package-owned resume kind when this value is an exact built-in registration.
    var registeredResumeKind: RegisteredAgentResumeKind? {
        if self == Self.builtInPi { return .pi }
        if self == Self.builtInOmp { return .omp }
        if self == Self.builtInCampfire { return .campfire }
        if self == Self.builtInAntigravity { return .antigravity }
        if self == Self.builtInGrok { return .grok }
        if self == Self.builtInKimi { return .kimi }
        if self == Self.builtInVibe { return .vibe }
        return nil
    }
}
