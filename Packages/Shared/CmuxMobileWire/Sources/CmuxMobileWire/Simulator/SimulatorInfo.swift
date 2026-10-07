/// One iOS simulator of the Mac in `simulator.list`.
public struct SimulatorInfo: Hashable, Sendable, Codable {
    public enum State: String, Hashable, Sendable, Codable {
        case booted
        case shutdown
    }

    public var udid: String
    public var name: String
    /// Runtime display name, for example `iOS 27.0`.
    public var runtime: String
    public var state: State

    public init(udid: String, name: String, runtime: String, state: State) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
    }
}
