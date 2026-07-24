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

    func referencesSameAllocation(
        as other: VerifiedReplayRendererSurfaceIdentity
    ) -> Bool {
        id == other.id
            && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
    }
}

/// Event-driven fence for one explicitly tokened Ghostty Metal submission.
/// A stale command-buffer completion cannot arm this fence even if its target
/// reaches both the model and presentation trees.
nonisolated struct VerifiedReplayPresentationFence: Sendable {
    private(set) var expectedToken: UInt64
    private(set) var expectedGeometryRevision: UInt64
    private(set) var expectedGeometry: VerifiedReplayPresentationGeometry
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

    mutating func restart(
        expectedToken: UInt64,
        expectedGeometryRevision: UInt64,
        expectedGeometry: VerifiedReplayPresentationGeometry,
        observedFrameReady: Bool = false
    ) {
        self.expectedToken = expectedToken
        self.expectedGeometryRevision = expectedGeometryRevision
        self.expectedGeometry = expectedGeometry
        acknowledgedIdentity = nil
        self.observedFrameReady = observedFrameReady
    }

    mutating func acknowledge(
        token: UInt64,
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        geometryRevision: UInt64,
        geometry: VerifiedReplayPresentationGeometry?
    ) -> Bool {
        guard acknowledgementFailureReason(
            token: token,
            modelIdentity: modelIdentity,
            geometryRevision: geometryRevision,
            geometry: geometry
        ) == nil,
              let modelIdentity else {
            return false
        }
        acknowledgedIdentity = modelIdentity
        return true
    }

    func acknowledgementFailureReason(
        token: UInt64,
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        geometryRevision: UInt64,
        geometry: VerifiedReplayPresentationGeometry?
    ) -> String? {
        if token != expectedToken { return "token_mismatch" }
        guard let modelIdentity else { return "model_surface_missing" }
        if geometryRevision != expectedGeometryRevision { return "geometry_revision_changed" }
        if geometry != expectedGeometry { return "model_geometry_changed" }
        if !verifiedReplaySurfaceExtentMatchesGeometry(modelIdentity, geometry: expectedGeometry) {
            return "model_extent_mismatch"
        }
        return nil
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
              modelIdentity.referencesSameAllocation(as: acknowledgedIdentity),
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
        // including between the sequential model- and presentation-tree reads.
        // Compare the allocation ID and pixel extent, which remain stable.
        // Ordinary rendering remains suppressed for the lifetime of this
        // fence, so no later command can reuse it.
        return presentationIdentity.referencesSameAllocation(as: modelIdentity)
    }

    func unsatisfiedReason(
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        presentationIdentity: VerifiedReplayRendererSurfaceIdentity?,
        geometryRevision: UInt64,
        modelGeometry: VerifiedReplayPresentationGeometry?,
        presentationGeometry: VerifiedReplayPresentationGeometry?
    ) -> String {
        if let reason = readinessFailureReason(
            modelIdentity: modelIdentity,
            presentationIdentity: presentationIdentity
        ) {
            return reason
        }
        if let reason = geometryFailureReason(
            modelIdentity: modelIdentity,
            presentationIdentity: presentationIdentity,
            geometryRevision: geometryRevision,
            modelGeometry: modelGeometry,
            presentationGeometry: presentationGeometry
        ) {
            return reason
        }
        return "satisfied"
    }

    private func readinessFailureReason(
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        presentationIdentity: VerifiedReplayRendererSurfaceIdentity?
    ) -> String? {
        if !observedFrameReady { return "frame_not_ready" }
        guard let acknowledgedIdentity else { return "submission_not_acknowledged" }
        guard let modelIdentity else { return "model_surface_missing" }
        guard presentationIdentity != nil else { return "presentation_surface_missing" }
        if !modelIdentity.referencesSameAllocation(as: acknowledgedIdentity) {
            return "model_allocation_changed"
        }
        return nil
    }

    private func geometryFailureReason(
        modelIdentity: VerifiedReplayRendererSurfaceIdentity?,
        presentationIdentity: VerifiedReplayRendererSurfaceIdentity?,
        geometryRevision: UInt64,
        modelGeometry: VerifiedReplayPresentationGeometry?,
        presentationGeometry: VerifiedReplayPresentationGeometry?
    ) -> String? {
        guard let modelIdentity, let presentationIdentity else { return nil }
        if geometryRevision != expectedGeometryRevision { return "geometry_revision_changed" }
        if modelGeometry != expectedGeometry { return "model_geometry_changed" }
        if presentationGeometry != expectedGeometry { return "presentation_geometry_not_committed" }
        if !verifiedReplaySurfaceExtentMatchesGeometry(modelIdentity, geometry: expectedGeometry) {
            return "model_extent_mismatch"
        }
        if !verifiedReplaySurfaceExtentMatchesGeometry(presentationIdentity, geometry: expectedGeometry) {
            return "presentation_extent_mismatch"
        }
        if !presentationIdentity.referencesSameAllocation(as: modelIdentity) {
            return "presentation_allocation_not_committed"
        }
        return nil
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
