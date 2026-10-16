import Foundation

/// The outcome of judging one captured argv for an agent kind.
public enum AgentLaunchCaptureArgvVerdict: Equatable, Sendable {
    /// The argv describes a launch of the kind it was captured for.
    case trusted([String])
    /// The argv is not this agent's launch, on the named ground.
    case rejected(AgentLaunchCaptureRejectionReason)

    /// Judges a PID-derived argv candidate for `kind`, naming the ground when it
    /// cannot be trusted so a capture that stores no argv can record why.
    ///
    /// More than one ground can hold for the same argv — `zsh -lc "claude …"`
    /// read by the codex hook is both a shell dispatcher and another agent — so
    /// the order is a rule, not an accident of how the checks were written:
    /// **the record names the ground that stands on its own.** A `-c`
    /// invocation is not an agent launch for any kind, and would still be
    /// rejected if the descriptors matched; a kind mismatch is only a statement
    /// about this hook, and would disappear under another one. The unconditional
    /// ground is the one worth storing, so it is checked first.
    ///
    /// Trust does not depend on the order — an argv is `.trusted` only when
    /// every check passes, which `trustDecisionMatchesTheChecksItWraps` pins.
    public init(processName: String?, arguments: [String]?, kind: String) {
        guard let arguments, !arguments.isEmpty else {
            self = .rejected(.argvUnavailable)
            return
        }
        guard !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(arguments) else {
            self = .rejected(.argvLooksLikeShellWrapper)
            return
        }
        guard AgentLaunchCaptureTrust.nativeProcessDescribesKind(
            processName: processName,
            arguments: arguments,
            kind: kind
        ) else {
            self = .rejected(.nativeProcessDoesNotDescribeKind)
            return
        }
        self = .trusted(arguments)
    }
}
