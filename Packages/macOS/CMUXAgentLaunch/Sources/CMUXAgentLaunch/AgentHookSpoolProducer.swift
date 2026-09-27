import Foundation

/// Emits the shell command that publishes a queued hook event to the session
/// spool without starting the cmux CLI.
///
/// The command runs only zsh builtins when the wrapper exported a spool
/// directory (``spoolDirectoryEnvironmentKey``) and a forwarder owns it. In
/// every other case it runs `fallback`, the existing `cmux hooks enqueue`
/// command, with the hook's complete stdin, so an event is never dropped just
/// because the fast path is unavailable.
///
/// ```swift
/// let producer = AgentHookSpoolProducer(agent: "claude")
/// let command = producer.command(subcommand: "pre-tool-use", fallback: cliCommand)
/// ```
public struct AgentHookSpoolProducer: Sendable {
    /// The largest hook stdin published through the spool. Larger payloads
    /// take the CLI path, which compacts them before admission.
    public static let maximumPayloadBytes = 256 * 1_024

    /// The agent whose hooks this producer publishes, such as `claude`.
    public let agent: String

    /// Creates a producer for one agent.
    ///
    /// - Parameter agent: A lowercase agent name made of letters and digits.
    public init(agent: String) {
        self.agent = agent
    }

    /// The environment key naming the session spool directory.
    public var spoolDirectoryEnvironmentKey: String {
        "CMUX_\(agent.uppercased())_HOOK_SPOOL_DIR"
    }

    /// The environment key that disables this agent's cmux hooks.
    public var disableEnvironmentKey: String {
        "CMUX_\(agent.uppercased())_HOOKS_DISABLED"
    }

    /// Wraps a queued-hook CLI command with the spool fast path.
    ///
    /// - Parameters:
    ///   - subcommand: The queued hook subcommand, such as `pre-tool-use`.
    ///   - fallback: The complete existing admission command. It must read the
    ///     hook payload from stdin and print the agent's `{}` response.
    /// - Returns: A POSIX shell command for the agent's hook settings.
    public func command(subcommand: String, fallback: String) -> String {
        let pidKey = AgentHookDeliveryPolicy().pidEnvironmentVariable(agentName: agent)
        let spool = AgentHookSpoolDirectory.self
        // `exec` replaces the agent's hook shell. The agent reads its response
        // from fd 3: zsh sources /etc/zshenv even under -f, and anything that
        // file prints goes to stderr instead of the hook response. zsh -f loads
        // no user startup
        // files; sysread, epochtime, mv, rm and zsystem flock are module
        // builtins, so the published path starts no further process.
        // Ownership rule (see AgentHookSpoolDirectory): the record is renamed
        // into place first, then the forwarder lock is probed. If no forwarder
        // holds it, whichever of this producer or a drainer unlinks the record
        // owns the event, so it is admitted exactly once or by the fallback.
        let script = #"""
        LC_ALL=C
        export \#(pidKey)=${\#(pidKey):-$PPID}
        cmux_fallback() { { print -rn -- "$cmux_p"; /bin/cat; } | /bin/sh -c "$1" >&3; exit $?; }
        zmodload zsh/system zsh/datetime zsh/files 2>/dev/null || exec /bin/sh -c "$1" >&3
        cmux_p= cmux_c= cmux_e=0
        while (( ${#cmux_p} < \#(Self.maximumPayloadBytes) )); do sysread -i 0 -s 65536 cmux_c || { cmux_e=$?; break; }; cmux_p+=$cmux_c; done
        [[ -n ${CMUX_SURFACE_ID:-} && ${\#(disableEnvironmentKey):-} != 1 ]] || { (( cmux_e == 5 )) || /bin/cat >/dev/null; print -r -- '{}' >&3; exit 0; }
        cmux_d=$\#(spoolDirectoryEnvironmentKey)
        (( cmux_e == 5 )) && [[ -f $cmux_d/\#(spool.environmentKeysName) ]] || cmux_fallback "$1"
        cmux_r="\#(AgentHookSpoolRecord.formatMarker)"$'\n'"\#(agent)"$'\n'"$2"$'\n'
        for cmux_k in ${(f)"$(<$cmux_d/\#(spool.environmentKeysName))"}; do (( ${+parameters[$cmux_k]} )) && cmux_r+="$cmux_k=${(P)cmux_k}"$'\0'; done
        cmux_r+=$'\0'"$cmux_p"
        (( ${#cmux_r} <= \#(AgentHookSpoolDirectory.maximumRecordBytes) )) || cmux_fallback "$1"
        umask 077
        cmux_n=$cmux_d/$epochtime[1].$epochtime[2]-$$
        { print -rn -- "$cmux_r" >| $cmux_n.tmp && mv -f -- $cmux_n.tmp $cmux_n\#(spool.recordSuffix); } 2>/dev/null || { rm -f -- $cmux_n.tmp 2>/dev/null; cmux_fallback "$1"; }
        if zsystem flock -t 0 -r -f cmux_l $cmux_d/\#(spool.forwarderLockName) 2>/dev/null; then
          zsystem flock -u $cmux_l
          rm -- $cmux_n\#(spool.recordSuffix) 2>/dev/null && cmux_fallback "$1"
        fi
        print -r -- '{}' >&3
        """#
        return "if [ -n \"${\(spoolDirectoryEnvironmentKey):-}\" ] && [ -x /bin/zsh ]; then "
            + "exec /bin/zsh -fc \(Self.singleQuoted(script)) cmux-hook \(Self.singleQuoted(fallback)) \(subcommand) 3>&1 1>&2; "
            + "else \(fallback); fi"
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
