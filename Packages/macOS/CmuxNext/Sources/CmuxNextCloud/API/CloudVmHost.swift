public import Foundation

/// A Cloud machine's acpmux `vmHost` (acpmux `hub/vm_host.rs`): whether it is a dedicated agent
/// VM, where agents run without the sandbox and the owner's chats start without asking. On by
/// default on a machine cmux created for its owner; Settings > Machines turns it off and on.
///
/// Read and set over the Cloud API's exec, one short command each: the machine's own
/// `cmux-tui acp --json host vm-host [on|off]`, run as the machine's work user (or root on an
/// image from before the work user), which answers `{vmHost, cmuxVm, configured}`.
public enum CloudVmHost {
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
    public static let timeoutMs = 15_000

    /// The command that reads the setting (`on` nil) or sets it.
    public static func command(on: Bool?) -> String {
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
    public static func parse(_ ran: CloudExecResult) -> State? {
        guard ran.exitCode == 0, let start = ran.stdout.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(ran.stdout[start...].utf8)) as? [String: Any],
              let on = object["vmHost"] as? Bool else { return nil }
        return State(on: on, cmuxVM: object["cmuxVm"] as? Bool ?? false)
    }

    /// Why a failed exec failed, in the machine's words, bounded: acpmux's `--json` error
    /// envelope's message (`{"error": {"message": …}}`, pretty), else the first line.
    public static func failure(_ ran: CloudExecResult) -> String {
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
