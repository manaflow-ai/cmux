import CmuxLink
import CmuxMobileWire

/// What every session of one host shares: configuration, admission, the
/// workspace stream, the op path, the daemon and the pluggable handlers.
final class MobileHostContext: Sendable {
    let configuration: MobileHostConfiguration
    let authorizer: any MobileDeviceAuthorizer
    let owner: WorkspaceStreamOwner
    let executor: MobileOpExecutor
    let daemon: any MobileDaemon
    let handlers: MobileChannelHandlers
    let clock: LinkClock
    let tasks: MobileTaskService?

    init(configuration: MobileHostConfiguration, authorizer: any MobileDeviceAuthorizer, owner: WorkspaceStreamOwner,
         executor: MobileOpExecutor, daemon: any MobileDaemon, handlers: MobileChannelHandlers, clock: LinkClock,
         tasks: MobileTaskService? = nil) {
        self.tasks = tasks
        self.configuration = configuration
        self.authorizer = authorizer
        self.owner = owner
        self.executor = executor
        self.daemon = daemon
        self.handlers = handlers
        self.clock = clock
    }

    /// Routes an opened channel to its service by kind.
    func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
               gate: MobileSessionGate) async {
        switch open.kind {
        case .rpc:
            var reads = handlers.reads
            if let tasks { reads["task.list"] = TaskListReadHandler(service: tasks) }
            await MobileRpcService(channel: channel, principal: principal, owner: owner, executor: executor,
                                   readHandlers: reads, gate: gate,
                                   extraStreams: tasks.map { [$0.owner] } ?? []).run()
        case .terminal:
            await TerminalChannelBridge(channel: channel, open: open, principal: principal, owner: owner,
                                        daemon: daemon, gate: gate).run()
        default:
            guard let handler = handlers.channels[open.kind] else {
                await channel.refuse(code: "channel.unknown_kind", message: "\(open.kind.rawValue) is not served by this host")
                return
            }
            await handler.serve(channel, open: open, principal: principal, gate: gate)
        }
    }
}
