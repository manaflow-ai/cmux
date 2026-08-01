/// Whether Sparkle user-driver callbacks still belong to the active foreground check generation.
nonisolated enum UpdateCheckCallbackAcceptance {
    /// Apply callbacks to the model and expose their normal user interactions.
    case accepting

    /// A foreground deadline abandoned this generation; consume callbacks without mutating the
    /// model until Sparkle's authoritative cycle-finished signal arrives.
    case discardingUntilCycleFinishes
}
