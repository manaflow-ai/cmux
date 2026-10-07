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
    private let onAdmitted: @Sendable (MobileSessionServer, String) async -> Void

    init(configuration: MobileHostConfiguration, authorizer: any MobileDeviceAuthorizer, owner: WorkspaceStreamOwner,
         executor: MobileOpExecutor, daemon: any MobileDaemon, handlers: MobileChannelHandlers,
         onAdmitted: @escaping @Sendable (MobileSessionServer, String) async -> Void) {
        self.configuration = configuration
        self.authorizer = authorizer
        self.owner = owner
        self.executor = executor
        self.daemon = daemon
        self.handlers = handlers
        self.onAdmitted = onAdmitted
    }

    func register(_ server: MobileSessionServer, install: String) async {
        await onAdmitted(server, install)
    }

    /// Routes an opened channel to its service by kind.
    func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal) async {
        switch open.kind {
        case .rpc:
            await MobileRpcService(channel: channel, principal: principal, owner: owner, executor: executor,
                                   readHandlers: handlers.reads).run()
        case .terminal:
            await TerminalChannelBridge(channel: channel, open: open, principal: principal, owner: owner,
                                        daemon: daemon).run()
        default:
            guard let handler = handlers.channels[open.kind] else {
                await channel.refuse(code: "channel.unknown_kind", message: "\(open.kind.rawValue) is not served by this host")
                return
            }
            await handler.serve(channel, open: open, principal: principal)
        }
    }
}
