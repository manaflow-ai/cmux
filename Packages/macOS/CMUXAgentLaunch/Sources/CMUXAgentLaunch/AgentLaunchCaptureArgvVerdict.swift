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
    /// The grounds are checked most specific first, not in the order the hook
    /// happened to run them: a shell dispatcher (`sh -c …`) is not an agent
    /// launch whatever its process name resolves to, so it names itself instead
    /// of coming back as a kind mismatch. Trust is unaffected either way — an
    /// argv is `.trusted` only when both checks pass.
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
