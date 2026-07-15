import Foundation

public enum MobileMacPowerError: Error, Equatable, Sendable {
    case unavailable
    case unsupported
    case invalidResponse
}
