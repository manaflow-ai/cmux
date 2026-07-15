public import Foundation

/// Thin SSH/SCP front end for provisioning: builds OpenSSH argv (mirroring
/// the `cmux ssh` bootstrap defaults) and runs it through the injected
/// ``VPSCommandRunning`` seam.
///
/// Auth is fully delegated to OpenSSH — ssh config, agent, and identity
/// files resolve exactly as they do for `ssh` in a terminal. `BatchMode=yes`
/// makes missing/locked credentials fail fast with an actionable error
/// instead of hanging on a prompt.
public struct VPSSSHClient: Sendable {
    /// Host to talk to.
    public var host: VPSHostDescriptor
    private let runner: any VPSCommandRunning

    /// Creates a client for `host`.
    ///
    /// - Parameters:
    ///   - host: Connection identity.
    ///   - runner: Process runner seam; tests inject a fake.
    public init(host: VPSHostDescriptor, runner: any VPSCommandRunning) {
        self.host = host
        self.runner = runner
    }

    /// Common `ssh` argv for non-interactive exec, before destination and
    /// command. Exposed for argv-construction tests.
    public func sshCommonArguments() -> [String] {
        var arguments: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=20",
            "-o", "ControlMaster=no",
            "-o", "RequestTTY=no",
        ]
        if !hasOptionKey("StrictHostKeyChecking") {
            arguments += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if let port = host.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = host.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in host.sshOptions {
            arguments += ["-o", option]
        }
        return arguments
    }

    /// `scp` argv for uploading `localPath` to `remotePath`, exposed for
    /// argv-construction tests.
    public func scpArguments(localPath: String, remotePath: String) -> [String] {
        var arguments: [String] = [
            "-q",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
        ]
        if !hasOptionKey("StrictHostKeyChecking") {
            arguments += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if let port = host.port {
            arguments += ["-P", String(port)]
        }
        if let identityFile = host.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in host.sshOptions {
            arguments += ["-o", option]
        }
        arguments += [localPath, "\(host.destination):\(remotePath)"]
        return arguments
    }

    /// Runs `script` on the host via `sh -c '<script>'`.
    ///
    /// - Parameters:
    ///   - script: POSIX shell script text.
    ///   - timeout: Wall-clock limit in seconds.
    /// - Returns: Exit status and captured output.
    /// - Throws: ``VPSProvisioningError/sshFailed(detail:)`` when ssh cannot
    ///   launch or times out.
    public func runScript(_ script: String, timeout: TimeInterval) async throws -> VPSCommandResult {
        let command = "sh -c \(script.shellSingleQuoted)"
        do {
            return try await runner.run(
                executable: "/usr/bin/ssh",
                arguments: sshCommonArguments() + [host.destination, command],
                environment: nil,
                timeout: timeout
            )
        } catch let error as VPSProvisioningError {
            throw error
        } catch {
            throw VPSProvisioningError.sshFailed(detail: error.localizedDescription)
        }
    }

    /// Uploads `localPath` to `remotePath` with scp.
    ///
    /// - Parameters:
    ///   - localPath: Local file to upload.
    ///   - remotePath: Destination path on the host.
    ///   - timeout: Wall-clock limit in seconds.
    /// - Returns: Exit status and captured output.
    /// - Throws: ``VPSProvisioningError/sshFailed(detail:)`` when scp cannot
    ///   launch or times out.
    public func upload(localPath: String, remotePath: String, timeout: TimeInterval) async throws -> VPSCommandResult {
        do {
            return try await runner.run(
                executable: "/usr/bin/scp",
                arguments: scpArguments(localPath: localPath, remotePath: remotePath),
                environment: nil,
                timeout: timeout
            )
        } catch let error as VPSProvisioningError {
            throw error
        } catch {
            throw VPSProvisioningError.sshFailed(detail: error.localizedDescription)
        }
    }

    private func hasOptionKey(_ key: String) -> Bool {
        host.sshOptions.contains { option in
            guard let separator = option.firstIndex(of: "=") else { return false }
            return option[..<separator].trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(key) == .orderedSame
        }
    }
}
