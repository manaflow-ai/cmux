#if canImport(UIKit)
import CoreGraphics
import Foundation
import IOSurface

/// IOSurface identity plus its content seed at one renderer boundary.
nonisolated struct VerifiedReplayRendererSurfaceIdentity: Equatable, Sendable {
    let id: UInt32
    let seed: UInt32
}

/// Event-driven fence for one Ghostty Metal submission.
///
/// Ghostty changes its renderer layer contents only from the Metal command
/// buffer completion callback. Requiring the changed IOSurface to also appear
/// in the presentation tree ensures Core Animation accepted that completed
/// target before the last-good overlay can be removed.
nonisolated struct VerifiedReplayPresentationFence: Sendable {
    let initialIdentity: VerifiedReplayRendererSurfaceIdentity?

    func isSatisfied(
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        presentationIdentity: VerifiedReplayRendererSurfaceIdentity?
    ) -> Bool {
        guard let modelIdentity,
              modelIdentity != initialIdentity else {
            return false
        }
        return presentationIdentity == modelIdentity
    }
}

nonisolated enum VerifiedReplayFrameCapture {
    static func rendererIdentity(from contents: Any?) -> VerifiedReplayRendererSurfaceIdentity? {
        guard let surface = ioSurface(from: contents) else { return nil }
        return VerifiedReplayRendererSurfaceIdentity(
            id: IOSurfaceGetID(surface),
            seed: IOSurfaceGetSeed(surface)
        )
    }

    /// Copies the current renderer target into Data-backed immutable pixels.
    /// The resulting CGImage cannot be changed when Ghostty reuses its three
    /// IOSurface swap-chain targets.
    static func copyCGImage(from contents: Any?) -> CGImage? {
        guard let surface = ioSurface(from: contents) else { return nil }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        guard width > 0,
              height > 0,
              bytesPerRow >= width * 4,
              height <= Int.max / bytesPerRow else {
            return nil
        }

        guard IOSurfaceLock(surface, [.readOnly], nil) == 0 else {
            return nil
        }
        defer { IOSurfaceUnlock(surface, [.readOnly], nil) }
        let baseAddress = IOSurfaceGetBaseAddress(surface)
        let pixels = Data(bytes: baseAddress, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func ioSurface(from contents: Any?) -> IOSurface? {
        guard let contents else { return nil }
        let value = contents as CFTypeRef
        guard CFGetTypeID(value) == IOSurfaceGetTypeID() else { return nil }
        return (contents as! IOSurface)
    }
}
#endif
