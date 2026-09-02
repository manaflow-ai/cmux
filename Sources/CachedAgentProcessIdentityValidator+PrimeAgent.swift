import CMUXAgentLaunch
import Foundation

extension CachedAgentProcessIdentityValidator {
    /// Applies the Prime-specific executable identity rule used by both the
    /// cached validator and the broader live-process scanner. A bare runtime
    /// basename is not enough: an unrelated Node process must not keep a
    /// Prime session looking live after the original process exits.
    static func primeAgentExecutableIdentityMatches(
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String]
    ) -> Bool {
        PrimeAgentProcessIdentity().matchesRecordedProcess(
            liveExecutable: liveExecutable,
            recordedExecutable: recordedExecutable,
            arguments: arguments
        )
    }

    /// Prime's released launcher is commonly a Node/Bun/tsx process whose
    /// argv points at the Prime Agent coding-agent bundle rather than a binary
    /// named `prime-agent`. Keep the path check narrow enough not to bless an
    /// arbitrary JavaScript runtime as the recorded agent.
    static func livePrimeAgentProcessExecutableMatches(
        kind: RestorableAgentKind,
        liveExecutable: String,
        arguments: [String]
    ) -> Bool {
        guard kind == .primeAgent else { return false }
        return PrimeAgentProcessIdentity().matchesRuntimeProcess(
            processName: liveExecutable,
            arguments: arguments
        )
    }
}
