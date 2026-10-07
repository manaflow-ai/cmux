/// A fixed ICE configuration (tests, previews, a DEV override).
public struct StaticICEServerProvider: ICEServerProvider {
    public var configuration: ICEConfiguration

    public init(_ configuration: ICEConfiguration = .hostOnly) {
        self.configuration = configuration
    }

    public func iceConfiguration(for hostID: String) async throws -> ICEConfiguration {
        configuration
    }
}
