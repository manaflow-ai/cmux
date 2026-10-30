import Foundation

extension Duration {
    /// The duration in seconds, for Core Animation's media time (`HoverCardPanel`'s sweep check).
    nonisolated var hoverCardSeconds: CFTimeInterval {
        let parts = components
        return CFTimeInterval(parts.seconds) + CFTimeInterval(parts.attoseconds) / 1e18
    }
}
