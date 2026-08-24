import CmuxSimulator
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SimulatorMobileFrameFormat: Equatable, Sendable {
    case jpeg(quality: Double)
    case png

    var uniformTypeIdentifier: String {
        switch self {
        case .jpeg:
            return UTType.jpeg.identifier
        case .png:
            return UTType.png.identifier
        }
    }
}

public struct SimulatorMobileFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let format: SimulatorMobileFrameFormat
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let displayScale: Double
    public let data: Data

    public init(
        sequence: UInt64,
        format: SimulatorMobileFrameFormat,
        pixelWidth: Int,
        pixelHeight: Int,
        displayScale: Double,
        data: Data
    ) {
        self.sequence = sequence
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayScale = displayScale
        self.data = data
    }
}

/// Checked `Sendable`: both stored properties are immutable, and
/// `SimulatorFrameSurfaceReading` requires `Sendable` of its conformers
/// (`SimulatorFrameSurfaceSource` documents its own seqlock/immutable-mapping
/// safety), so the compiler can verify this type without `@unchecked`.
public final class SimulatorMobileFrameReader: Sendable {
    private let source: any SimulatorFrameSurfaceReading
    private let displayScale: Double

    init(source: any SimulatorFrameSurfaceReading, displayScale: Double) {
        self.source = source
        self.displayScale = displayScale
    }

    public func hasPublishedFrame(after sequence: UInt64?) -> Bool {
        source.hasPublishedFrame(after: sequence)
    }

    public func setFramePublicationHandler(_ handler: (@Sendable () -> Void)?) -> Bool {
        source.setFramePublicationHandler(handler)
    }

    public func copyLatestFrame(
        after sequence: UInt64?,
        format: SimulatorMobileFrameFormat = .jpeg(quality: 0.72)
    ) async -> SimulatorMobileFrame? {
        guard let snapshot = await source.copyLatestFrame(after: sequence),
              let presentation = SimulatorFramePresentation(snapshot: snapshot),
              let data = Self.encode(presentation.image, as: format) else { return nil }
        return SimulatorMobileFrame(
            sequence: presentation.sequence,
            format: format,
            pixelWidth: presentation.image.width,
            pixelHeight: presentation.image.height,
            displayScale: displayScale,
            data: data
        )
    }

    private static func encode(_ image: CGImage, as format: SimulatorMobileFrameFormat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.uniformTypeIdentifier as CFString,
            1,
            nil
        ) else { return nil }
        let options: CFDictionary?
        switch format {
        case let .jpeg(quality):
            options = [kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))] as CFDictionary
        case .png:
            options = nil
        }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension SimulatorPaneCoordinator {
    public func makeMobileFrameReader() -> SimulatorMobileFrameReader? {
        guard let frameTransport, let display else { return nil }
        guard let source = try? SimulatorFrameSurfaceSource(descriptor: frameTransport) else { return nil }
        return SimulatorMobileFrameReader(source: source, displayScale: display.scale)
    }
}
