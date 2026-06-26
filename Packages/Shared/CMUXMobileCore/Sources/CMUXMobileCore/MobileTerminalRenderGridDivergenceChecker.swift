import Foundation

/// Decides when the consumer should verify that its applied terminal grid still
/// matches the producer's authoritative grid, and whether a mismatch warrants a
/// keyframe.
///
/// The verification itself (reading the applied grid back out of libghostty via
/// `ghostty_surface_render_grid_json`) takes the same surface lock as
/// `process_output`, so running it on every frame would contend that lock on the
/// typing-latency render path and risk the exact freeze it is meant to detect.
/// This checker throttles verification to at most once per ``minInterval`` so the
/// read-back cost stays bounded, and keeps the throttle clock injectable so the
/// policy is testable without sleeping or touching libghostty.
///
/// Usage on the consumer:
/// 1. After applying a render-grid frame, call ``shouldVerify(expectedHash:now:)``.
/// 2. If it returns `true`, read the applied grid hash and call
///    ``diverges(expectedHash:appliedHash:)``.
/// 3. If that returns `true`, request a full keyframe (resync).
public struct MobileTerminalRenderGridDivergenceChecker: Sendable {
    /// Minimum seconds between read-backs. The read-back walks the whole grid, so
    /// this bounds its amortized cost on the render path.
    public var minInterval: Double

    private var lastVerifyTime: Double

    /// - Parameter minInterval: Minimum seconds between verifications (default
    ///   0.25s: fast enough that a stuck-blank row repairs almost immediately,
    ///   slow enough that streaming output does not pay a read-back per frame).
    public init(minInterval: Double = 0.25) {
        self.minInterval = minInterval
        self.lastVerifyTime = -.infinity
    }

    /// Whether the caller should perform the (expensive) applied-grid read-back
    /// now, given the hash stamped on the frame it just applied and a monotonic
    /// timestamp.
    ///
    /// Returns `false` when the frame carries no hash (a producer that predates
    /// the field) or when a verification happened within ``minInterval``. When it
    /// returns `true` it records `now` as the last verify time, so the throttle
    /// advances only on an actual check.
    public mutating func shouldVerify(expectedHash: UInt64?, now: Double) -> Bool {
        guard expectedHash != nil else { return false }
        guard now - lastVerifyTime >= minInterval else { return false }
        lastVerifyTime = now
        return true
    }

    /// Whether a completed read-back disagrees with the authoritative hash, i.e.
    /// the consumer must request a keyframe. `false` when either hash is missing,
    /// so a failed read-back never triggers a spurious resync loop.
    public func diverges(expectedHash: UInt64?, appliedHash: UInt64?) -> Bool {
        guard let expectedHash, let appliedHash else { return false }
        return expectedHash != appliedHash
    }
}
