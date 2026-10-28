public import Foundation

extension CloudMachineRepo {
    /// Retries a repository-only setup on the same machine, without creating a machine or
    /// repeating a custom bootstrap. The existing runner's locks serialize the start.
    ///
    /// The original setup must contain this same repository and the no-op script. A different
    /// repository or custom script fails closed under the runner lock, leaving its files intact.
    /// Callers keep the original account/team scope and cancel this operation when it changes.
    public func retry(on machine: CloudMachineBootstrap.Machine) async -> CloudMachineBootstrap.Run {
        guard !Task.isCancelled else { return .stillRunning }
        guard Self.isPathComponent(owner), Self.isPathComponent(name), ref.map(Self.isRef) ?? true else {
            return .repoFailed(repo: "")
        }
        let bootstrap = CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript, repo: self)
        let outcome = await bootstrap.start(name: nil, on: machine, repositoryOnly: true)
        guard !Task.isCancelled else { return .stillRunning }
        switch outcome.status {
        case "started", "skipped": return await bootstrap.waitForRun(on: machine)
        case "running": return .stillRunning
        default: return .repoFailed(repo: "\(owner)/\(name)")
        }
    }
}
