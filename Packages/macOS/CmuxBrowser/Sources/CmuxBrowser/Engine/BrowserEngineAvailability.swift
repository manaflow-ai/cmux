import Foundation

/// Whether an engine can create pages in this process.
public enum BrowserEngineAvailability: Equatable, Hashable, Sendable {
    /// The engine can create pages.
    case available
    /// The engine cannot create pages, for the given reason.
    case unavailable(BrowserEngineUnavailableReason)

    /// `true` for ``available``.
    public var isAvailable: Bool { self == .available }

    /// The reason for ``unavailable(_:)``, otherwise `nil`.
    public var unavailableReason: BrowserEngineUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
