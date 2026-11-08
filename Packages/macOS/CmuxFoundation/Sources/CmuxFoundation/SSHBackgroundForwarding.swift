/// The forwarding a background ssh run turns off when it only executes a
/// helper command.
///
/// OpenSSH keeps the first value it reads for most options, so callers place
/// ``optionArguments`` before any configured options.
///
/// ```swift
/// args += SSHBackgroundForwarding.allOff.optionArguments
/// ```
public enum SSHBackgroundForwarding: Sendable, Equatable {
    /// Agent and X11 forwarding off. Use on runs that set up their own `-L`
    /// or `-R` forward, which `ClearAllForwardings` would also drop.
    case agentAndX11Off

    /// Agent, X11 and every configured port forward off.
    case allOff

    /// The `-o` overrides as an argv fragment.
    public var optionArguments: [String] {
        let agentAndX11Off = [
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
        ]
        switch self {
        case .agentAndX11Off:
            return agentAndX11Off
        case .allOff:
            return agentAndX11Off + ["-o", "ClearAllForwardings=yes"]
        }
    }
}
