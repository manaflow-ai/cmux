import CmuxFoundation
import Foundation

extension CMUXCLI {
    func resolvedUserSSHControlOptions(for options: SSHCommandOptions) -> [String]? {
        guard let output = resolvedSSHConfigurationOutput(for: options) else { return nil }
        return SSHConnectionSharingOptions()
            .userConfiguredControlOptions(fromSSHConfigOutput: output)
    }

    func resolvedCmuxControlPathOptions(for options: SSHCommandOptions) -> [String] {
        let sharingOptions = SSHConnectionSharingOptions()
        guard let configuredPath = sharingOptions.cmuxOwnedControlPath(in: options.sshOptions),
              configuredPath.contains("%"),
              let output = resolvedSSHConfigurationOutput(for: options),
              let resolvedPath = sshConfigurationValue(named: "controlpath", in: output) else {
            return options.sshOptions
        }
        let validationOptions = ["ControlMaster=auto", "ControlPath=\(resolvedPath)"]
        guard sharingOptions.cmuxOwnedControlPath(in: validationOptions) == resolvedPath else {
            return options.sshOptions
        }
        let resolver = SSHAgentSocketResolver()
        return options.sshOptions.map { option in
            resolver.optionKey(option) == "controlpath"
                ? "ControlPath=\(resolvedPath)"
                : option
        }
    }

    func resolvedSSHConfigurationOutput(for options: SSHCommandOptions) -> String? {
        var arguments = ["-G"]
        if let port = options.port {
            arguments += ["-p", String(port)]
        }
        if let rawIdentityFile = options.identityFile {
            let trimmedIdentityFile = rawIdentityFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedIdentityFile.isEmpty {
                let identityFile = trimmedIdentityFile.hasPrefix("~")
                    ? (trimmedIdentityFile as NSString).expandingTildeInPath
                    : trimmedIdentityFile
                arguments += ["-i", identityFile]
            }
        }
        for option in options.sshOptions {
            arguments += ["-o", option]
        }
        arguments.append(options.destination)
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/ssh",
            arguments: arguments,
            timeout: 2
        )
        return result.status == 0 ? result.stdout : nil
    }

    func sshConfigurationValue(named name: String, in output: String) -> String? {
        let loweredName = name.lowercased()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0].lowercased() == loweredName else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
