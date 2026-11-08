import CMUXAgentLaunch
import Foundation

extension SurfaceResumeBindingSnapshot {
    /// Validates an unquoted selector token shared by restore and fork startup inputs.
    static func restoreCLIArgument(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return AgentRestoreCLIArgument(rawValue: value)?.rawValue
    }

    /// Returns the shell-free fork selector for a local binding, or the
    /// compatibility command for a binding whose process executes remotely.
    ///
    /// Remote SSH/tmux bindings deliberately keep their provider command unless
    /// their transport supplies a reachable cmux relay. The caller chooses the
    /// binding's launch flavor before this method is used.
    func forkStartupInput(
        repairPortableAgentExecutable: Bool = true
    ) -> String? {
        if usesLocalForkVerb {
            let executable = AgentRestoreLaunch.cliStartupExecutableToken
            if let kind = Self.restoreCLIArgument(kind),
               let checkpointId = Self.restoreCLIArgument(checkpointId) {
                return " \(executable) fork \(kind) \(checkpointId)\n"
            }
            return " \(executable) fork --surface\n"
        }
        guard let inline = inlineStartupInput(
            repairPortableAgentExecutable: repairPortableAgentExecutable
        ) else {
            return nil
        }
        let command = inline.hasSuffix("\n") ? String(inline.dropLast()) : inline
        return TerminalStartupTypedShellCommand().typedInput(posixCommand: command) + "\n"
    }

    /// Local bindings can resolve the fork record through the local cmux
    /// socket. Remote bindings need a transport-provided relay and otherwise
    /// retain their provider command.
    var usesLocalForkVerb: Bool {
        launchFlavor == .local
    }
}
