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
    public struct State: Equatable, Sendable, Decodable {
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

    /// The command that reads the setting (`on` nil) or sets it (cmux-cloud-machine `vm_host.rs`).
    public func command(on: Bool?) -> String {
        struct Request: Encodable { var on: Bool? }
        struct Reply: Decodable { var command: String }
        return CloudMachineRules().call("cloud_model_vm_host_command", Request(on: on), as: Reply.self)?.command ?? "exit 82"
    }

    /// What an exec answered: the state, or why it failed, in the machine's words, bounded.
    private struct Answer: Decodable {
        var state: State?
        var failure: String?
    }

    private func answer(_ ran: CloudExecResult) -> Answer {
        struct Request: Encodable { var exitCode: Int, stdout: String, stderr: String }
        let request = Request(exitCode: Int(ran.exitCode), stdout: ran.stdout, stderr: ran.stderr)
        return CloudMachineRules().call("cloud_model_vm_host_answer", request, as: Answer.self) ?? Answer(failure: "exit \(ran.exitCode)")
    }

    /// The state in a successful exec's output, or nil.
    public func parse(_ ran: CloudExecResult) -> State? { answer(ran).state }

    /// Why a failed exec failed: acpmux's `--json` error envelope's message, else the first line.
    public func failure(_ ran: CloudExecResult) -> String { answer(ran).failure ?? "exit \(ran.exitCode)" }
}
