/// `cloud.machine_stream {machine}` → `{socket}`: the local socket each connection
/// of which reaches a Cloud machine's session daemon over the app's link, as the app's own chat pane attaches. It is
/// what `cloud exec` already lets this user reach on the machine, through the link instead of the Cloud API. `cmux cloud start-chat --wait` observes
/// the chat's turn there (cmux-tui cloud_start_chat/link_wait.rs) instead of polling `cloud exec ... acp wait` (Leo,
/// 2026-11-10: "have we figured out where the 26.5 seconds were yet?"). No link up: `machine_stream.unavailable`.
public struct CloudMachineStreamControl {
    public init() {}
    public static func method(_ socket: @escaping @Sendable (_ machine: String) async -> String?) -> ControlMethod {
        .async("cloud.machine_stream") { call in
            guard let machine = call.params["machine"]?.stringValue else { throw ControlError.invalidParams("needs machine") }
            guard let path = await socket(machine) else { throw ControlError(code: "machine_stream.unavailable", message: "no link to machine \(machine)") }
            return ["socket": .string(path)]
        }.withDeadline(.fixed(.seconds(10)))
    }
}
