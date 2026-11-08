import CoreGraphics
import Foundation

/// Computes Mac-style click counts from successive phone taps.
///
/// The mirror preserves Mac pointer semantics: a double tap is a double click
/// (word selection), a triple tap a triple click (paragraph selection). Taps
/// are forwarded immediately with a rising click count, exactly like a
/// physical mouse, so single clicks never wait on a double-tap recognizer to
/// fail. Zooming belongs to the pinch gesture alone.
struct BrowserStreamTapClickCounter {
    /// Maximum seconds between taps that still chain the click count.
    let chainInterval: TimeInterval
    /// Maximum view-point distance between taps that still chain the count.
    let chainRadius: CGFloat

    private var lastTime: TimeInterval?
    private var lastLocation: CGPoint?
    private var count = 0

    /// Creates a counter with Mac-like double-click chaining thresholds.
    /// - Parameters:
    ///   - chainInterval: Seconds within which a tap continues the chain.
    ///   - chainRadius: View points within which a tap continues the chain.
    init(chainInterval: TimeInterval = 0.45, chainRadius: CGFloat = 28) {
        self.chainInterval = chainInterval
        self.chainRadius = chainRadius
    }

    /// Registers one tap and returns the click count to forward to the Mac.
    /// - Parameters:
    ///   - location: The tap location in view points.
    ///   - time: A monotonic timestamp for the tap.
    /// - Returns: The Mac click count for this tap (1 for a lone tap, 2 for a
    ///   double click, and so on).
    mutating func register(at location: CGPoint, time: TimeInterval) -> Int {
        if let lastTime, let lastLocation,
           time - lastTime <= chainInterval,
           hypot(location.x - lastLocation.x, location.y - lastLocation.y) <= chainRadius {
            count += 1
        } else {
            count = 1
        }
        lastTime = time
        lastLocation = location
        return count
    }
}
