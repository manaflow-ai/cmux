import Foundation

/// Main-actor gate used by service tests to model a temporarily unavailable target.
@MainActor
final class DeliveryGate {
    var isReady = false
}
