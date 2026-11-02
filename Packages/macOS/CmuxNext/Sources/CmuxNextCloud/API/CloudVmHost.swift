public import Foundation

/// A Cloud machine's acpmux `vmHost` (acpmux `hub/vm_host.rs`): whether it takes its owner's VM
/// boundary when the owner's own app link asks for it, nothing more. The machine never decides
/// that: a remote chain from this app's link runs without the sandbox (and, for a peer session
/// that asked no policy, on Linux, while MDM allows, approves all) only when the Cloud API told
/// this app it owns the machine (`vmKind: "owner"`, acpmux `hub/vm_boundary.rs`). Team VMs and
/// every other caller keep the sandbox, and chats this app starts there (`agent-session-start`)
/// start with policy `ask`. On by default on any Linux machine; off makes the machine refuse the
/// boundary (the sandbox always), on returns to the default. Settings > Machines shows the switch
/// only while the link says the caller owns the machine.
///
/// Read and set over the Cloud API's exec, one short command each: the machine's own
/// `cmux-tui acp --json host vm-host [on|off]`, run as the machine's work user (or root on an
/// image from before the work user), which answers `{vmHost, cmuxVm, configured}`. A value the
/// caller builds (``CloudVmHostStore`` holds one), with the exec budget it runs under.
public struct CloudVmHost: Sendable {
    /// What the machine said.
    public struct State: Equatable, Sendable {
        /// On now.
        public var on: Bool
        /// cmux created this machine for its owner, so on is its default and may be turned on.
        public var cmuxVM: Bool

        public init(on: Bool, cmuxVM: Bool) {
            self.on = on
            self.cmuxVM = cmuxVM
        }
    }

    /// The exec's budget: well under the exec API's 25 s.
    public let timeoutMs: Int

    public init(timeoutMs: Int = 15_000) {
        self.timeoutMs = timeoutMs
    }

    /// The command that reads the setting (`on` nil) or sets it.
    public func command(on: Bool?) -> String {
        let state = on.map { $0 ? " on" : " off" } ?? ""
        return [
            "set -eu",
            #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#,
            #"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#,
            #"u=cmux; id -u "$u" >/dev/null 2>&1 || u=root"#,
            #"h=$(getent passwd "$u" | cut -d: -f6)"#,
            #"b="$h/.cmux/bin/cmux-tui""#,
            #"[ -x "$b" ] || { echo "cmux: this machine has no cmux-tui" >&2; exit 82; }"#,
            #"as_u env HOME="$h" "$b" acp --json host vm-host\#(state)"#,
        ].joined(separator: "; ")
    }

    /// The state in a successful exec's output (acpmux prints one JSON object, pretty), or nil.
    public func parse(_ ran: CloudExecResult) -> State? {
        guard ran.exitCode == 0, let start = ran.stdout.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(ran.stdout[start...].utf8)) as? [String: Any],
              let on = object["vmHost"] as? Bool else { return nil }
        return State(on: on, cmuxVM: object["cmuxVm"] as? Bool ?? false)
    }

    /// Why a failed exec failed, in the machine's words, bounded: acpmux's `--json` error
    /// envelope's message (`{"error": {"message": …}}`, pretty), else the first line.
    public func failure(_ ran: CloudExecResult) -> String {
        let text = ran.stderr.isEmpty ? ran.stdout : ran.stderr
        if let start = text.firstIndex(of: "{"),
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
           let message = (object["error"] as? [String: Any])?["message"] as? String {
            return String(message.prefix(300))
        }
        // Not acpmux's envelope (an older cmux-tui's usage error, the shell's): its first line.
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(ran.exitCode)"
        return String(line.prefix(300))
    }
}
