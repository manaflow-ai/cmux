public import CmuxTerminalRenderTransport
public import CoreGraphics
internal import Foundation
internal import IOSurface
public import QuartzCore

/// Integer pixel dimensions expected from a Ghostty render worker.
public struct GhosttyRenderPixelSize: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32

    /// Creates an expected remote-frame size.
    public init(width: UInt32, height: UInt32) {
        self.width = width
        self.height = height
    }
}

/// Presents generation-fenced IOSurfaces received from a Ghostty render worker.
///
/// All configuration and frame presentation happens on the main actor. The
/// layer explicitly retains its last accepted IOSurface while a worker is
/// unavailable or its mirror is being reconfigured, avoiding a blank terminal
/// between worker generations.
public final class GhosttyRemoteIOSurfaceLayer: CALayer {
    /// State accessed only by the main-actor APIs below. CALayer's required
    /// `init(layer:)` remains nonisolated because Core Animation may create a
    /// presentation-layer copy off the main thread; that copy gets inert state
    /// and inherits only CALayer's visual properties.
    private final class PresentationState: @unchecked Sendable {
        let surfaceID: UUID
        var workerGeneration: UInt64?
        var surfaceGeneration: UInt64
        var expectedPixelSize: GhosttyRenderPixelSize
        var lastAcceptedFrameSequence: UInt64?
        var retainedSurface: IOSurfaceRef?

        init(
            surfaceID: UUID,
            workerGeneration: UInt64?,
            surfaceGeneration: UInt64,
            expectedPixelSize: GhosttyRenderPixelSize
        ) {
            self.surfaceID = surfaceID
            self.workerGeneration = workerGeneration
            self.surfaceGeneration = surfaceGeneration
            self.expectedPixelSize = expectedPixelSize
        }
    }

    private let presentationState: PresentationState

    /// Stable identity of the terminal surface this layer presents.
    @MainActor public var surfaceID: UUID { presentationState.surfaceID }

    /// Worker generation currently allowed to present, or nil after exit.
    @MainActor public var workerGeneration: UInt64? { presentationState.workerGeneration }

    /// Native mirror generation currently allowed to present.
    @MainActor public var surfaceGeneration: UInt64 { presentationState.surfaceGeneration }

    /// Pixel dimensions currently desired by AppKit for diagnostics and scheduling.
    @MainActor public var expectedPixelSize: GhosttyRenderPixelSize {
        presentationState.expectedPixelSize
    }

    /// Last accepted sequence in the current worker and surface generation.
    @MainActor public var lastAcceptedFrameSequence: UInt64? {
        presentationState.lastAcceptedFrameSequence
    }

    // An explicit strong reference documents and enforces the last-frame
    // retention contract independently of CALayer.contents implementation
    // details. Tests inspect it through @testable import.
    @MainActor internal var retainedSurface: IOSurfaceRef? {
        presentationState.retainedSurface
    }

    /// Creates a layer for one terminal mirror generation.
    @MainActor public init(
        surfaceID: UUID,
        workerGeneration: UInt64,
        surfaceGeneration: UInt64,
        expectedPixelSize: GhosttyRenderPixelSize,
        backingScaleFactor: CGFloat
    ) {
        self.presentationState = PresentationState(
            surfaceID: surfaceID,
            workerGeneration: workerGeneration,
            surfaceGeneration: surfaceGeneration,
            expectedPixelSize: expectedPixelSize
        )
        super.init()
        configurePresentation(backingScaleFactor: backingScaleFactor)
    }

    override public init(layer: Any) {
        self.presentationState = PresentationState(
            surfaceID: UUID(),
            workerGeneration: nil,
            surfaceGeneration: 0,
            expectedPixelSize: GhosttyRenderPixelSize(width: 0, height: 0)
        )
        super.init(layer: layer)
    }

    @available(*, unavailable, message: "Use init(surfaceID:workerGeneration:surfaceGeneration:expectedPixelSize:backingScaleFactor:)")
    override public init() {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "GhosttyRemoteIOSurfaceLayer does not support archival")
    required public init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    /// Updates the worker generation and permits its sequence to start over.
    /// The last frame remains visible until the new worker presents a match.
    @MainActor public func updateWorkerGeneration(_ generation: UInt64) {
        guard presentationState.workerGeneration != generation else { return }
        presentationState.workerGeneration = generation
        presentationState.lastAcceptedFrameSequence = nil
    }

    /// Fences late frames after a worker exits while retaining its last frame.
    /// A stale exit notification cannot invalidate a newer worker generation.
    @MainActor public func invalidateWorkerGeneration(_ generation: UInt64) {
        guard presentationState.workerGeneration == generation else { return }
        presentationState.workerGeneration = nil
        presentationState.lastAcceptedFrameSequence = nil
    }

    /// Updates the mirrored native-surface generation.
    /// The last frame remains visible while the new mirror starts rendering.
    @MainActor public func updateSurfaceGeneration(_ generation: UInt64) {
        guard presentationState.surfaceGeneration != generation else { return }
        presentationState.surfaceGeneration = generation
        presentationState.lastAcceptedFrameSequence = nil
    }

    /// Updates AppKit's desired pixel dimensions without clearing the last frame.
    @MainActor public func updateExpectedPixelSize(_ size: GhosttyRenderPixelSize) {
        presentationState.expectedPixelSize = size
    }

    /// Updates point-to-pixel mapping when the view changes backing display.
    @MainActor public func updateBackingScaleFactor(_ backingScaleFactor: CGFloat) {
        contentsScale = Self.validatedBackingScaleFactor(backingScaleFactor)
    }

    /// Presents a frame when every identity, generation, sequence, and internal
    /// dimension fence matches. Rejected frames leave the current contents untouched.
    @discardableResult
    @MainActor public func present(_ frame: TerminalRenderFrame) -> Bool {
        let metadata = frame.metadata
        guard metadata.surfaceID == presentationState.surfaceID,
              let workerGeneration = presentationState.workerGeneration,
              metadata.workerGeneration == workerGeneration,
              metadata.surfaceGeneration == presentationState.surfaceGeneration,
              IOSurfaceGetWidth(frame.surface) == Int(metadata.width),
              IOSurfaceGetHeight(frame.surface) == Int(metadata.height),
              presentationState.lastAcceptedFrameSequence.map({ metadata.frameSequence > $0 }) ?? true else {
            return false
        }

        // Keep the surface alive before making it visible. Disable implicit
        // contents animation so each worker frame replaces its predecessor
        // atomically instead of cross-fading terminal pixels.
        presentationState.retainedSurface = frame.surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = frame.surface
        CATransaction.commit()
        presentationState.lastAcceptedFrameSequence = metadata.frameSequence
        return true
    }

    @MainActor private func configurePresentation(backingScaleFactor: CGFloat) {
        contentsGravity = .topLeft
        contentsScale = Self.validatedBackingScaleFactor(backingScaleFactor)
    }

    private static func validatedBackingScaleFactor(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return max(1, scale)
    }
}
