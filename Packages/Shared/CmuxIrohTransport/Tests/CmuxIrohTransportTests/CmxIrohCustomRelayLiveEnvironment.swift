import Foundation
@testable import CmuxIrohTransport

enum CmxIrohCustomRelayLiveEnvironment {
    enum EnvironmentError: Error {
        case invalid(String)
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

    static var hasEndpointBoundTokenRelay: Bool {
        [
            "CMUX_IROH_CUSTOM_RELAY_BOUND_URL",
            "CMUX_IROH_CUSTOM_RELAY_FIRST_SECRET_KEY_HEX",
            "CMUX_IROH_CUSTOM_RELAY_FIRST_TOKEN",
            "CMUX_IROH_CUSTOM_RELAY_SECOND_SECRET_KEY_HEX",
            "CMUX_IROH_CUSTOM_RELAY_SECOND_TOKEN",
        ].allSatisfy { environment[$0]?.isEmpty == false }
    }

    static var hasBrokerCredentials: Bool {
        [
            "CMUX_IROH_CUSTOM_RELAY_BROKER_URL",
            "CMUX_IROH_CUSTOM_RELAY_ACCESS_TOKEN",
            "CMUX_IROH_CUSTOM_RELAY_REFRESH_TOKEN",
        ].allSatisfy { environment[$0]?.isEmpty == false }
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

    static func requiredSecretKey(_ name: String) throws -> CmxIrohSecretKey {
        let value = try required(name)
        guard value.utf8.count == 64 else {
            throw EnvironmentError.invalid(name)
        }
        var bytes = Data(capacity: 32)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else {
                throw EnvironmentError.invalid(name)
            }
            bytes.append(byte)
            index = next
        }
        return try CmxIrohSecretKey(bytes: bytes)
    }
}
