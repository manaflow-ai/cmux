import Foundation

enum CmxIrohCustomRelayLiveEnvironment {
    enum EnvironmentError: Error {
        case missing(String)
    }

    static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool {
        environment["CMUX_IROH_CUSTOM_RELAY_LIVE"] == "1"
    }

    static var hasNoTokenRelay: Bool {
        environment["CMUX_IROH_CUSTOM_RELAY_NO_TOKEN_URL"]?.isEmpty == false
    }

    static var hasStaticTokenRelay: Bool {
        environment["CMUX_IROH_CUSTOM_RELAY_STATIC_URL"]?.isEmpty == false
            && environment["CMUX_IROH_CUSTOM_RELAY_STATIC_TOKEN"]?.isEmpty == false
    }

    static var timeout: TimeInterval {
        environment["CMUX_IROH_CUSTOM_RELAY_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 10
    }

    static func required(_ name: String) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw EnvironmentError.missing(name)
        }
        return value
    }
}
