public import Foundation

/// A completed passive icon lookup, or a temporary failure that a reader may retry once.
public nonisolated enum AgentPaneSourceIconResult: Equatable, Sendable {
    /// A bounded raster PNG.
    case icon(Data)
    /// Discovery completed without a usable icon.
    case unavailable
    /// Admission, cancellation, a deadline or transport failure prevented discovery.
    case temporary

    var png: Data? {
        if case .icon(let data) = self { return data }
        return nil
    }
}
