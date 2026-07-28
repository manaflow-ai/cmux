import CmuxSimulator

struct ApplicationSurfaceSessionDescriptor: Equatable, Sendable {
    let sessionID: String
    let frameTransport: SimulatorFrameTransportDescriptor
}
