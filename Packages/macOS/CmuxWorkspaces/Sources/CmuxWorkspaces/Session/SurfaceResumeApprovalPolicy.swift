/// The approval disposition recorded for a surface-resume binding: whether the
/// stored command must be re-approved manually, prompts the user before
/// resuming, or resumes automatically.
///
/// The raw values are persisted verbatim in the surface-resume approval store
/// and embedded in `SurfaceResumeBindingSnapshot`, so they are wire-stable.
public enum SurfaceResumeApprovalPolicy: String, Codable, CaseIterable, Sendable {
    /// Resume only after the user manually approves the stored command again.
    case manual
    /// Prompt the user each time before resuming the stored command.
    case prompt
    /// Resume the stored command automatically without prompting.
    case auto
}
