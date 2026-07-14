#if canImport(UIKit)
import CoreGraphics
import Foundation
import IOSurface

/// IOSurface identity plus its content seed at one renderer boundary.
nonisolated struct VerifiedReplayRendererSurfaceIdentity: Equatable, Sendable {
    let id: UInt32
    let seed: UInt32
}

/// Event-driven fence for one explicitly tokened Ghostty Metal submission.
/// A stale command-buffer completion cannot arm this fence even if its target
/// reaches both the model and presentation trees.
nonisolated struct VerifiedReplayPresentationFence: Sendable {
    let expectedToken: UInt64
    private(set) var acknowledgedIdentity: VerifiedReplayRendererSurfaceIdentity?
    private(set) var observedFrameReady = false

    mutating func markObservedFrameReady() {
        observedFrameReady = true
    }

    mutating func acknowledge(
        token: UInt64,
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?
    ) -> Bool {
        guard token == expectedToken,
              let modelIdentity else {
            return false
        }
        acknowledgedIdentity = modelIdentity
        return true
    }

    func isSatisfied(
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        presentationIdentity: VerifiedReplayRendererSurfaceIdentity?
    ) -> Bool {
        guard observedFrameReady,
              let acknowledgedIdentity,
              let modelIdentity,
              let presentationIdentity,
              modelIdentity.id == acknowledgedIdentity.id else {
            return false
        }
        // The token identifies the exact completed Metal command and its
        // assigned IOSurface allocation. IOSurface's seed is a mutable content
        // version and can advance while Core Animation adopts that allocation,
        // so comparing the later seed to the callback-time seed deadlocks a
        // correctly presented frame. Ordinary rendering remains suppressed
        // for the lifetime of this fence, so no later command can reuse it.
        return presentationIdentity == modelIdentity
    }
}

/// Keeps authoritative grid export and its tokened Metal submission adjacent
/// inside one serial surface-queue closure. Publishing the exported frame to
/// MainActor happens only after this synchronous operation returns.
nonisolated enum VerifiedReplayAtomicSubmission {
    static func exportThenSubmit<Frame>(
        export: () -> Frame?,
        submit: () -> Void
    ) -> Frame? {
        guard let frame = export() else { return nil }
        submit()
        return frame
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
        return contents as? IOSurface
    }
}
#endif
