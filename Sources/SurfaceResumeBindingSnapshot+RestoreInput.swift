import CMUXAgentLaunch
import Foundation

extension SurfaceResumeBindingSnapshot {
    func inlineStartupInput(
        repairPortableAgentExecutable: Bool,
        includeWorkingDirectoryPrefix: Bool = true,
        registration: CmuxVaultAgentRegistration? = nil
    ) -> String? {
        guard restoreWorkingDirectorySelection?.permitsResume != false else {
            return nil
        }
        let resolvedCommand: String
        if let selection = restoreWorkingDirectorySelection,
           selection.discardsRecordedCwdOptions {
            guard let constrainedCommand = constrainedRestoreCommand(
                selection: selection,
                includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix,
                registration: registration,
                repairPortableAgentExecutable: repairPortableAgentExecutable
            ) else {
                return nil
            }
            resolvedCommand = constrainedCommand
        } else {
            resolvedCommand = resolvedStartupCommand(
                repairPortableAgentExecutable: repairPortableAgentExecutable
            )
        }
        let command = includeWorkingDirectoryPrefix
            ? resolvedCommand
            : TerminalStartupWorkingDirectoryPrefix.removingRequiredChangeDirectoryPrefix(
                from: resolvedCommand,
                workingDirectory: cwd
            )
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Stays raw POSIX: remote restores (remoteStartupInput) hand this to
        // the remote host's shell, and local callers apply the nushell dialect
        // envelope at their own typed boundary (restoreStartupInput). Wrapping
        // here would leak `^/bin/sh …` into contexts that parse POSIX.
        guard let environment, !environment.isEmpty else {
            return trimmed + "\n"
        }
        let assignments = environment.keys.sorted().compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }
        let argv = ["/usr/bin/env"] + assignments + ["/bin/zsh", "-lc", trimmed]
        return argv.map(Self.shellSingleQuoted).joined(separator: " ") + "\n"
    }

    func restoreStartupInput(
        repairPortableAgentExecutable: Bool
    ) -> String? {
        if usesLocalRestoreVerb {
            // Bare words (` cmux restore <kind> <id>`): parses identically in
            // POSIX shells and nushell, no dialect handling needed.
            return localRestoreCLIInput
        }
        guard let inline = inlineStartupInput(
            repairPortableAgentExecutable: repairPortableAgentExecutable
        ) else {
            return nil
        }
        // The compatibility fallback is a POSIX one-liner typed into the local
        // login shell, so it is the nushell dialect boundary (the trailing
        // newline stays outside the wrap). Remote hosts keep raw POSIX via
        // remoteStartupInput().
        let command = inline.hasSuffix("\n") ? String(inline.dropLast()) : inline
        return TerminalStartupTypedShellCommand().typedInput(posixCommand: command) + "\n"
    }

    func remoteStartupInput(
        registration: CmuxVaultAgentRegistration? = nil
    ) -> String? {
        inlineStartupInput(
            repairPortableAgentExecutable: false,
            registration: registration
        )
    }

    var localRestoreCLIInput: String {
        let executable = AgentRestoreLaunch.cliStartupExecutableToken
        if let kind = Self.restoreCLIArgument(kind),
           let checkpointId = Self.restoreCLIArgument(checkpointId) {
            return " \(executable) restore \(kind) \(checkpointId)\n"
        }
        return " \(executable) restore --surface\n"
    }

    func resolvedStartupCommand(repairPortableAgentExecutable: Bool) -> String {
        guard isAgentHookBinding else {
            return startupCommand
        }
        let suppressed = SurfaceResumeCommandCanonicalizer.insertingCodexUpdateCheckSuppression(
            in: startupCommand,
            kind: kind
        )
        let repaired: String
        if repairPortableAgentExecutable {
            repaired = SurfaceResumeCommandCanonicalizer.replacingPortableAgentExecutable(
                in: suppressed,
                kind: kind
            )
        } else {
            repaired = suppressed
        }
        guard let restoreLaunch = AgentRestoreLaunch(kind: kind, sessionID: checkpointId) else { return repaired }
        return restoreLaunch.applying(toStoredCommand: repaired)
    }
}
