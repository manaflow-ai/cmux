import CmuxNextActions
import CmuxNextRemote
import CmuxNextWindowRules
import Foundation

/// Forward Port…, List Forwarded Ports and Stop Forwarding Port… for an SSH machine: each asks the machine's link on
/// its admin socket (`SSHLinkAdmin`, cmux-remote `link_ports.rs`), so the bytes go through the connection the app has.
extension RemoteHandlers {
    static func bindPortActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        for (id, needsPort) in [("machine.portForward", true), ("machine.portList", false), ("machine.portClose", true)] as [(ActionID, Bool)] {
            // action-wait-allow: the answer comes from the machine's link socket, which no local state stands in for.
            CloudHandlers.bind(id, registry, reason: reason) { invocation in
                // A menu or palette run without --port asks for it.
                if needsPort, invocation["port"] == nil, CloudHandlers.origin(of: invocation) == .user,
                   registry.ask(id, invocation, ActionArgumentAsk(argument: "port")) { return }
                let session = try machine(invocation, context), port = needsPort ? try portArgument(invocation) : 0, name = session.host.label
                guard session.daemon.connection != nil else { throw ActionFailure(message: RemoteStrings.notConnected(name)) }
                let title = registry.title(for: id) ?? ""
                CloudHandlers.answer(title, invocation, context) {
                    guard let admin = await session.link.linkAdmin() else { throw ActionFailure(message: RemoteStrings.notConnected(name)) }
                    let fail = { (why: String?) in ActionFailure(message: why ?? RemoteStrings.linkDidNotAnswer(name)) }
                    switch id {
                    case "machine.portForward":
                        let answered = await admin.portForward(port: port)
                        guard case .success(let forward) = answered else { throw fail(answered.reason) }
                        if CloudHandlers.origin(of: invocation) == .user { context.copy(forward.url) }
                        return CloudAnswer(title: title, text: RemoteStrings.portForwarded(port, name, forward.url), fields: forwardFields(forward))
                    case "machine.portList":
                        let answered = await admin.portList()
                        guard case .success(let forwards) = answered else { throw fail(answered.reason) }
                        return CloudAnswer(title: title, text: WindowRules().portListText(forwards.map { .init(port: $0.port, url: $0.url) }) ?? RemoteStrings.noForwardedPorts(name),
                                           fields: ["forwards": .array(forwards.map { .object(forwardFields($0)) })])
                    default:
                        switch await admin.portClose(port: port) {
                        case .success(true): return CloudAnswer(title: title, text: RemoteStrings.portClosed(port, name), copyable: false, fields: ["port": .int(port), "closed": .bool(true)])
                        case .success(false): throw ActionFailure(message: RemoteStrings.portNotForwarded(port, name))
                        case .failure(let why): throw fail(why)
                        }
                    }
                }
            }
        }
    }

    /// `--port N`, 1 to 65535 (Rust's `handlers_verbs::port_argument`).
    static func portArgument(_ invocation: ActionInvocation) throws -> Int {
        let value = invocation["port"]
        let port = value?.intValue.map(WindowRules.PortValue.int) ?? value?.stringValue.map(WindowRules.PortValue.text)
        guard let port = WindowRules().portArgument(port) else { throw ActionFailure(message: RemoteStrings.needsPort) }
        return port
    }

    /// The fields `cmux machine port-forward` answers, as the link names them (`LinkForward`).
    static func forwardFields(_ forward: SSHLinkForward) -> [String: ActionResultValue] {
        ["port": .int(forward.port), "host": .string(forward.host), "local_port": .int(forward.localPort), "url": .string(forward.url)]
    }
}
