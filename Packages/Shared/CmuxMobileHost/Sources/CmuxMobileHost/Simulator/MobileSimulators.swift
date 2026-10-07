import CmuxLink
import CmuxMobileWire

/// The simulator family on this Mac: register `simulator` and `simulator.list`.
public struct MobileSimulators: Sendable {
    public let host: any SimulatorCaptureHost
    private let clock: LinkClock

    public init(host: any SimulatorCaptureHost, clock: LinkClock = .continuous) {
        self.host = host
        self.clock = clock
    }

    public func registering(into handlers: MobileChannelHandlers = MobileChannelHandlers()) -> MobileChannelHandlers {
        var channels = handlers.channels
        var reads = handlers.reads
        channels[.simulator] = SimulatorChannelHandler(simulators: host, clock: clock)
        reads["simulator.list"] = SimulatorListReadHandler(simulators: host)
        return MobileChannelHandlers(channels: channels, reads: reads)
    }
}
