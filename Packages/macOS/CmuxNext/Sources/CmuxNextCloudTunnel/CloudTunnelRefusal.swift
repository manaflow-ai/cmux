public import Foundation

/// A Cloud Tunnel request that ``CloudTunnelController/change(on:byPerson:settingIsOn:writeSetting:)``
/// turns down before it changes anything.
///
/// ``message`` is the localized text shown to the person or printed by the CLI.
public struct CloudTunnelRefusal: Error, LocalizedError, Equatable {
    /// Why the request was turned down, for the person.
    public let message: String

    /// Makes a refusal.
    /// - Parameter message: Why the request was turned down, already localized.
    public init(message: String) { self.message = message }

    /// The same text as ``message``.
    public var errorDescription: String? { message }
}
