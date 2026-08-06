import Foundation

/// Stable identity of the probed harness executable. `stat` follows symlinks,
/// while `realPath` also binds discovery to the resolved install target.
struct AgentConversationForkExecutableIdentity: Equatable, Hashable, Sendable {
    let lookupPath: String
    let realPath: String
    let fingerprint: String

    static func capture(
        executablePath: String,
        runtimeSearchPath: String?
    ) -> Self? {
        var environment: [String: String] = [:]
        if let runtimeSearchPath,
           !runtimeSearchPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["PATH"] = runtimeSearchPath
        }
        guard let identity = AgentForkSupport.forkProbeExecutableIdentity(
            executable: executablePath,
            processEnvironment: environment,
            workingDirectory: nil
        ) else {
            return nil
        }
        return Self(
            lookupPath: identity.lookupPath,
            realPath: identity.realPath,
            fingerprint: identity.cachePart
        )
    }
}
