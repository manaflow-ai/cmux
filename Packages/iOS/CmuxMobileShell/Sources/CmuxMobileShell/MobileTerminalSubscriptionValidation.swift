import Foundation

/// The exact connection and event-listener generation whose server-side
/// subscription has been acknowledged.
struct MobileTerminalSubscriptionValidation: Equatable, Sendable {
    let connectionGeneration: UUID
    let listenerID: UUID?
}
