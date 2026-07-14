#if canImport(UIKit)
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

/// IOSurface allocation, content seed, and exact pixel extent at one renderer
/// boundary. The extent ties the completed Metal target to the fenced layer
/// geometry instead of accepting a stretched or cropped target.
nonisolated struct VerifiedReplayRendererSurfaceIdentity: Equatable, Sendable {
    let id: UInt32
    let seed: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Event-driven fence for one explicitly tokened Ghostty Metal submission.
/// A stale command-buffer completion cannot arm this fence even if its target
/// reaches both the model and presentation trees.
nonisolated struct VerifiedReplayPresentationFence: Sendable {
    let expectedToken: UInt64
    let expectedGeometryRevision: UInt64
    let expectedGeometry: VerifiedReplayPresentationGeometry
    private(set) var acknowledgedIdentity: VerifiedReplayRendererSurfaceIdentity?
    private(set) var observedFrameReady = false

    init(
        expectedToken: UInt64,
        expectedGeometryRevision: UInt64,
        expectedGeometry: VerifiedReplayPresentationGeometry
    ) {
        self.expectedToken = expectedToken
        self.expectedGeometryRevision = expectedGeometryRevision
        self.expectedGeometry = expectedGeometry
    }

    mutating func markObservedFrameReady() {
        observedFrameReady = true
    }

    mutating func acknowledge(
        token: UInt64,
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        geometryRevision: UInt64,
        geometry: VerifiedReplayPresentationGeometry?
    ) -> Bool {
        guard token == expectedToken,
              let modelIdentity,
              geometryRevision == expectedGeometryRevision,
              geometry == expectedGeometry,
              verifiedReplaySurfaceExtentMatchesGeometry(
                modelIdentity,
                geometry: expectedGeometry
              ) else {
            return false
        }
        acknowledgedIdentity = modelIdentity
        return true
    }

    func isSatisfied(
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        presentationIdentity: VerifiedReplayRendererSurfaceIdentity?,
        geometryRevision: UInt64,
        modelGeometry: VerifiedReplayPresentationGeometry?,
        presentationGeometry: VerifiedReplayPresentationGeometry?
    ) -> Bool {
        guard observedFrameReady,
              let acknowledgedIdentity,
              let modelIdentity,
              let presentationIdentity,
              modelIdentity.id == acknowledgedIdentity.id,
              geometryRevision == expectedGeometryRevision,
              modelGeometry == expectedGeometry,
              presentationGeometry == expectedGeometry,
              verifiedReplaySurfaceExtentMatchesGeometry(
                modelIdentity,
                geometry: expectedGeometry
              ),
              verifiedReplaySurfaceExtentMatchesGeometry(
                presentationIdentity,
                geometry: expectedGeometry
              ) else {
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

func verifiedReplayPresentationGeometry(
    renderer: CALayer?,
    host: CALayer,
    viewportRect: CGRect
) -> VerifiedReplayPresentationGeometry? {
    guard let renderer else { return nil }
    return VerifiedReplayPresentationGeometry(
        rendererFrame: renderer.frame,
        rendererBounds: renderer.bounds,
        rendererPosition: renderer.position,
        rendererAnchorPoint: renderer.anchorPoint,
        rendererContentsScale: renderer.contentsScale,
        rendererTransform: verifiedReplayTransformScalars(renderer.transform),
        hostBounds: host.bounds,
        hostPosition: host.position,
        hostAnchorPoint: host.anchorPoint,
        hostTransform: verifiedReplayTransformScalars(host.transform),
        viewportRect: viewportRect
    )
}

/// Keeps authoritative grid export and its tokened Metal submission adjacent
/// inside one serial surface-queue closure. Publishing the exported frame to
/// MainActor happens only after this synchronous operation returns.
func verifiedReplayExportThenSubmit<Frame>(
    export: () -> Frame?,
    submit: () -> Void
) -> Frame? {
    guard let frame = export() else { return nil }
    submit()
    return frame
}

func verifiedReplayRendererIdentity(
    from contents: Any?
) -> VerifiedReplayRendererSurfaceIdentity? {
    guard let surface = verifiedReplaySurfaceCapture(from: contents)?.surface else { return nil }
    return VerifiedReplayRendererSurfaceIdentity(
        id: IOSurfaceGetID(surface),
        seed: IOSurfaceGetSeed(surface),
        pixelWidth: IOSurfaceGetWidth(surface),
        pixelHeight: IOSurfaceGetHeight(surface)
    )
}

/// Copies the current renderer target into Data-backed immutable pixels.
/// The resulting CGImage cannot be changed when Ghostty reuses its three
/// IOSurface swap-chain targets.
func copyVerifiedReplayCGImage(from contents: Any?) -> CGImage? {
    guard let capture = verifiedReplaySurfaceCapture(from: contents) else { return nil }
    return copyVerifiedReplayCGImage(from: capture)
}

func copyVerifiedReplayCGImage(from capture: VerifiedReplaySurfaceCapture) -> CGImage? {
    let surface = capture.surface
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

func verifiedReplaySurfaceCapture(from contents: Any?) -> VerifiedReplaySurfaceCapture? {
    guard let contents else { return nil }
    let value = contents as CFTypeRef
    guard CFGetTypeID(value) == IOSurfaceGetTypeID() else { return nil }
    guard let surface = contents as? IOSurface else { return nil }
    return VerifiedReplaySurfaceCapture(surface: surface)
}

private func verifiedReplayTransformScalars(_ transform: CATransform3D) -> [CGFloat] {
    [
        transform.m11, transform.m12, transform.m13, transform.m14,
        transform.m21, transform.m22, transform.m23, transform.m24,
        transform.m31, transform.m32, transform.m33, transform.m34,
        transform.m41, transform.m42, transform.m43, transform.m44
    ]
}

private func verifiedReplaySurfaceExtentMatchesGeometry(
    _ identity: VerifiedReplayRendererSurfaceIdentity,
    geometry: VerifiedReplayPresentationGeometry
) -> Bool {
    let expectedWidth = Int((geometry.rendererBounds.width * geometry.rendererContentsScale).rounded())
    let expectedHeight = Int((geometry.rendererBounds.height * geometry.rendererContentsScale).rounded())
    return identity.pixelWidth == expectedWidth && identity.pixelHeight == expectedHeight
}
#endif
