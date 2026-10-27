import CmuxNextRemoteView
import CoreVideo
import Dispatch
import IOSurface

/// Where a live simulator's frames go, from any thread: each SimulatorKit frame becomes a pixel
/// buffer over the simulator's own IOSurface (no copy) and goes to remote view presenter A, which
/// draws and presents it on its render queue (p03-rendering-114). Only the first frame of a session
/// and a new size take a main-thread turn. After the session's gate closes no frame reaches the
/// presenter, even one already on its way.
nonisolated struct PhoneLiveFrames: Sendable {
    let gate: RemoteFrameGate
    let presenter: any RemoteFramePresenter

    /// Shows `surface`; false when the session ended (the gate is closed) or it cannot be wrapped.
    @discardableResult
    func frame(_ surface: IOSurface) -> Bool { // perf-hot: 100us phone-surface-present (every simulator frame)
        var wrapped: Unmanaged<CVPixelBuffer>?
        // SAFETY: Core Video writes one +1 buffer to the local `wrapped`, live for the call; the
        // next line takes that +1 exactly once.
        guard unsafe CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &wrapped) == kCVReturnSuccess,
              // SAFETY: as above, the +1 buffer Core Video just made, taken once.
              let buffer = unsafe wrapped?.takeRetainedValue() else { return false }
        // The surface's seed changes with every write, so it numbers the frames.
        let frame = RemoteDecodedFrame(pixelBuffer: buffer, frame: IOSurfaceGetSeed(surface), tCaptureMicros: 0,
                                       decodedAtNanos: DispatchTime.now().uptimeNanoseconds)
        return gate.deliver(frame, to: presenter)
    }

    /// Whether presenter A draws `surface`'s pixel format (it draws NV12 and four-channel RGB).
    static func canDraw(_ surface: IOSurface) -> Bool {
        RemoteFramePresenters().draws(pixelFormat: IOSurfaceGetPixelFormat(surface))
    }
}
