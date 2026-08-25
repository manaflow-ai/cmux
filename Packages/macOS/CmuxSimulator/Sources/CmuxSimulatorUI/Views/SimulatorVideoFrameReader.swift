import CmuxSimulator
import Foundation

/// One deep-copied packed-BGRA frame for a video encoder.
///
/// Unlike `SimulatorMobileFrame` this carries raw pixels, not an encoded
/// image: the mobile video pipeline hands them to VideoToolbox, so any
/// image-codec round trip here would only add latency.
public struct SimulatorVideoFrame: Equatable, Sendable {
    public let pixels: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let sequence: UInt64

    public init(pixels: Data, width: Int, height: Int, bytesPerRow: Int, sequence: UInt64) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.sequence = sequence
    }
}

/// Checked `Sendable`: stored properties are immutable and
/// `SimulatorFrameSurfaceReading` requires `Sendable` of its conformers.
public final class SimulatorVideoFrameReader: Sendable {
    private let source: any SimulatorFrameSurfaceReading
    public let displayScale: Double

    init(source: any SimulatorFrameSurfaceReading, displayScale: Double) {
        self.source = source
        self.displayScale = displayScale
    }

    public func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        source.hasPublishedFrame(after: sequence)
    }

    /// Installs or removes a frame-publication wakeup. Returns whether the
    /// source can signal; callers without a signal must poll at display cadence.
    @discardableResult
    public func setFramePublicationHandler(_ handler: (@Sendable () -> Void)?) -> Bool {
        source.setFramePublicationHandler(handler)
    }

    /// Copies the newest stable frame newer than `sequence`, or nil when no
    /// newer publication exists.
    public func copyLatestFrame(after sequence: UInt64?) async -> SimulatorVideoFrame? {
        guard let snapshot = await source.copyLatestFrame(after: sequence) else { return nil }
        return SimulatorVideoFrame(
            pixels: snapshot.pixels,
            width: snapshot.width,
            height: snapshot.height,
            bytesPerRow: snapshot.bytesPerRow,
            sequence: snapshot.sequence
        )
    }
}

extension SimulatorPaneCoordinator {
    /// Builds a raw-pixel reader for the current frame transport, or nil while
    /// the worker's shared memory is still settling.
    public func makeVideoFrameReader() -> SimulatorVideoFrameReader? {
        guard let frameTransport, let display else { return nil }
        guard let source = try? SimulatorFrameSurfaceSource(descriptor: frameTransport) else {
            return nil
        }
        return SimulatorVideoFrameReader(source: source, displayScale: display.scale)
    }
}
