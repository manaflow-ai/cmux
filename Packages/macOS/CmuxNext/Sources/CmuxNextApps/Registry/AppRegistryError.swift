import Foundation

/// Refusals of the app registry.
public nonisolated enum AppRegistryError: Error, Equatable, Sendable {
    /// First-party apps can be hidden, never removed.
    case firstPartyHideOnly(String)
}
