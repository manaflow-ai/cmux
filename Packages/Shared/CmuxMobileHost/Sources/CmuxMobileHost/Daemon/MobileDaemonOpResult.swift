import CmuxMobileWire

/// The value an op returns (`result.value`).
public struct MobileDaemonOpResult: Hashable, Sendable {
    public var value: JSONValue

    public init(value: JSONValue = .object([:])) {
        self.value = value
    }
}
