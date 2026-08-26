import Foundation

extension CachedAgentProcessIdentityValidator {
    private static let primeAgentRuntimeNames: Set<String> = ["node", "bun", "deno", "tsx", "ts-node"]

    /// Applies the Prime-specific executable identity rule used by both the
    /// cached validator and the broader live-process scanner. A bare runtime
    /// basename is not enough: an unrelated Node process must not keep a
    /// Prime session looking live after the original process exits.
    static func primeAgentExecutableIdentityMatches(
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String]
    ) -> Bool {
        let liveBase = (liveExecutable as NSString).lastPathComponent.lowercased()
        let recordedBase = (recordedExecutable as NSString).lastPathComponent.lowercased()
        if liveBase == "prime-agent" && recordedBase == "prime-agent" {
            return true
        }
        guard primeAgentRuntimeNames.contains(liveBase)
            || primeAgentRuntimeNames.contains(recordedBase) else {
            return false
        }
        return livePrimeAgentProcessExecutableMatches(
            kind: .primeAgent,
            liveExecutable: liveBase,
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
        let runtimeNames: Set<String> = ["node", "bun", "deno", "tsx", "ts-node"]
        guard runtimeNames.contains((liveExecutable as NSString).lastPathComponent.lowercased()) else {
            return false
        }
        return arguments.dropFirst().contains { argument in
            let normalized = argument.replacingOccurrences(of: "\\", with: "/").lowercased()
            let basename = (normalized as NSString).lastPathComponent
            let knownEntrypoint = ["cli.js", "cli.ts", "index.js", "index.ts"].contains(basename)
            let hasPrimePackageMarker = normalized.contains("/.prime/agent/")
                || normalized.contains("/prime-agent/")
                || normalized.contains("/@earendil-works/pi-coding-agent/")
            let hasCodingAgentMarker = normalized.contains("/coding-agent/")
                || normalized.contains("/pi-coding-agent/")
                || knownEntrypoint
            return hasPrimePackageMarker && hasCodingAgentMarker
        }
    }
}
