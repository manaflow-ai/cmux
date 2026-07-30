internal import CmuxCore
internal import CmuxFoundation
internal import Foundation

/// Resolves a cmux-owned OpenSSH ControlPath to the exact local socket path.
struct NativeSSHControlPathResolver: Sendable {
    let sharingOptions: SSHConnectionSharingOptions

    func resolutionArguments(
        configuration: WorkspaceRemoteConfiguration,
        effectiveOptions: [String]
    ) -> [String] {
        var arguments = ["-G"]
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in effectiveOptions {
            arguments += ["-o", option]
        }
        arguments.append(configuration.destination)
        return arguments
    }

    func resolvedControlPath(
        effectiveOptions: [String],
        sshConfigOutput: String? = nil
    ) -> String? {
        guard let ownedPath = sharingOptions.cmuxOwnedControlPath(
            in: effectiveOptions
        ) else {
            return nil
        }
        guard ownedPath.contains("%") else { return ownedPath }
        guard let sshConfigOutput else { return nil }
        for line in sshConfigOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  parts[0].lowercased() == "controlpath" else {
                continue
            }
            let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.contains("%") else { return nil }
            let resolvedOptions = replacingControlPath(
                in: effectiveOptions,
                with: path
            )
            return sharingOptions.cmuxOwnedControlPath(in: resolvedOptions)
        }
        return nil
    }

    func replacingControlPath(
        in effectiveOptions: [String],
        with resolvedControlPath: String
    ) -> [String] {
        let optionResolver = SSHAgentSocketResolver()
        return ["ControlPath=\(resolvedControlPath)"] + effectiveOptions.filter {
            optionResolver.optionKey($0) != "controlpath"
        }
    }
}
