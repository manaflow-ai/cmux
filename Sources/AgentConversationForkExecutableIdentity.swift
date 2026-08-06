import Darwin
import Foundation

/// Stable identity of the probed harness executable. `stat` follows symlinks,
/// while `realPath` also binds discovery to the resolved install target.
struct AgentConversationForkExecutableIdentity: Equatable, Hashable, Sendable {
    let lookupPath: String
    let realPath: String
    let fingerprint: String
    let device: UInt64
    let shellStatSignature: String

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
        var status = stat()
        guard stat(identity.realPath, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        let device = UInt64(status.st_dev)
        let shellStatSignature = [
            String(device),
            String(status.st_ino),
            String(status.st_mode, radix: 8),
            String(status.st_size),
            String(status.st_mtimespec.tv_sec),
        ].joined(separator: ":")
        return Self(
            lookupPath: identity.lookupPath,
            realPath: identity.realPath,
            fingerprint: identity.cachePart,
            device: device,
            shellStatSignature: shellStatSignature
        )
    }
}
