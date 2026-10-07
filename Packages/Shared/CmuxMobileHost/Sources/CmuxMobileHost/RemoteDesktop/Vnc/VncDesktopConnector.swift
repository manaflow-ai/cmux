public import CmuxLink
public import CmuxRemoteDesktop

/// Dials VNC servers for the Mac's proxy. As `RemoteDesktopSources` it
/// serves VNC targets only; `ScreenDesktopSources` delegates `.vnc` to it.
public struct VncDesktopConnector: RemoteDesktopSources {
    public let dial: @Sendable (VncAddress) async throws -> any RfbTransport
    public let makeEncoder: @Sendable () -> any BrowserFrameEncoder
    /// How long the peer may take to send its RFB ProtocolVersion.
    public let bannerTimeout: Duration
    public let clock: LinkClock

    public init(dial: @escaping @Sendable (VncAddress) async throws -> any RfbTransport,
                makeEncoder: @escaping @Sendable () -> any BrowserFrameEncoder = { VideoToolboxH264Encoder() },
                bannerTimeout: Duration = .seconds(10), clock: LinkClock = .continuous) {
        self.dial = dial
        self.makeEncoder = makeEncoder
        self.bannerTimeout = bannerTimeout
        self.clock = clock
    }

    public func displays() async -> [DesktopDisplay] { [] }
    public func windows() async -> [DesktopWindow] { [] }

    public func describe(_ target: DesktopTarget) async throws -> DesktopTargetInfo {
        switch target {
        case .display: throw RemoteDesktopSourceError.displayNotFound
        case .window: throw RemoteDesktopSourceError.windowNotFound
        case .vnc(let address):
            // The size is known after ServerInit; the session announces it then.
            return DesktopTargetInfo(kind: .vnc, width: 0, height: 0, scale: 1, name: address.name ?? address.host)
        }
    }

    public func open(_ request: RemoteDesktopOpenRequest) async throws -> any RemoteDesktopTarget {
        guard case .vnc(let address) = request.target else { throw RemoteDesktopSourceError.displayNotFound }
        let transport: any RfbTransport
        do {
            transport = try await dial(address)
        } catch {
            throw RemoteDesktopSourceError.vncUnreachable("\(address.host):\(address.port) did not answer")
        }
        let client = RfbClient(transport: transport)
        let clock = clock
        let timeout = bannerTimeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await client.negotiateVersion() }
                group.addTask {
                    try await clock.sleep(for: timeout)
                    await transport.close()
                    throw RfbError.notRfb
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            await transport.close()
            throw RemoteDesktopSourceError.vncUnreachable("\(address.host):\(address.port) is not a VNC server")
        }
        let target = RfbDesktopTarget(client: client, address: address, encoder: makeEncoder())
        await target.start()
        return target
    }
}
