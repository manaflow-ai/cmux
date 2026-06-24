import Foundation
import Network

extension NWError {
    /// Whether this error means the address/port cannot be bound (in use, not
    /// available, or permission denied) versus a transient waiting reason.
    ///
    /// The mobile host's bind loop uses this to distinguish a hard "this port is
    /// unusable" failure (give up / report port-in-use) from a `.waiting` state
    /// it should keep retrying. Modeled as an extension on `NWError` so the
    /// classification lives on the type it operates on rather than in a separate
    /// namespace.
    public var isAddressUnavailable: Bool {
        if case let .posix(code) = self {
            return code == .EADDRINUSE || code == .EADDRNOTAVAIL || code == .EACCES
        }
        return false
    }
}
