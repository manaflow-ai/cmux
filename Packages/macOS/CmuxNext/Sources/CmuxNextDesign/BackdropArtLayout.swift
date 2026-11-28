public import Foundation

/// A normalized point in an artwork, measured from the top-left corner.
public struct BackdropFocalAnchor: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public nonisolated init(x: Double, y: Double) {
        self.x = min(max(x.isFinite ? x : 0.5, 0), 1)
        self.y = min(max(y.isFinite ? y : 0.5, 0), 1)
    }

    public static let center = Self(x: 0.5, y: 0.5)
}

/// A normalized region that is intentionally kept visually quiet for chrome.
public struct BackdropQuietZone: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public nonisolated init(x: Double, y: Double, width: Double, height: Double) {
        let originX = min(max(x.isFinite ? x : 0, 0), 1)
        let originY = min(max(y.isFinite ? y : 0, 0), 1)
        self.x = originX
        self.y = originY
        self.width = min(max(width.isFinite ? width : 0, 0), 1 - originX)
        self.height = min(max(height.isFinite ? height : 0, 0), 1 - originY)
    }
}

