internal import Foundation
internal import CoreVideo

/// Owns the DEBUG-only `CVDisplayLink` capture lifecycle that drives the vsync
/// IOSurface timeline UI-test probe (the split-close-right blank-flash /
/// stretched-text regression scenario).
///
/// This is the irreducible app-adjacent seam that the pure
/// ``VsyncIOSurfaceTimelineAnalyzer`` cannot hold: the `CVDisplayLink`
/// create/start/stop, the `NSLock`-guarded in-flight/finished coordination read
/// from the C display-link callback thread, and the per-vsync main-thread
/// sampling. Each compositor frame it runs any scheduled actions due that frame,
/// samples its targets on the main actor, and feeds the resulting
/// ``VsyncFrameSample`` values into the analyzer.
///
/// The live layer / IOSurface reads stay app-side: each target is a
/// `@MainActor` closure that the app maps from its own `DebugFrameSample` to a
/// ``VsyncFrameSample`` at the call site, so this owner references no app type
/// or QuartzCore. The display link is created and started on the main actor in
/// ``run()``; the callback samples inside a `DispatchQueue.main.sync` block so a
/// single compositor-frame blank flash is never missed.
///
/// Isolation: not `Sendable`. The instance is handed to `CVDisplayLink` as an
/// opaque `Unmanaged` pointer and accessed from the display-link callback
/// thread only through the `NSLock`-guarded in-flight coordination; all mutation
/// of the analyzer and targets happens inside the callback's
/// `DispatchQueue.main.sync` block, matching the legacy single-threaded access.
///
/// `@unchecked Sendable` justification: the instance is deliberately shared
/// between the `@MainActor` `run()` caller and the C display-link callback
/// thread (it is handed to `CVDisplayLink` as an opaque pointer). The `NSLock`
/// serializes the only concurrently-touched fields (`inFlight` / `finished` /
/// `continuation`), and the analyzer/targets/action mutation happens solely
/// inside the callback's `DispatchQueue.main.sync` block, so cross-thread
/// access is hand-synchronized exactly as the legacy app-side capture was.
public final class VsyncIOSurfaceTimelineCapture: @unchecked Sendable {
    /// The pure per-frame blank / size-mismatch detector and trace recorder.
    let analyzer: VsyncIOSurfaceTimelineAnalyzer
    /// Guards ``inFlight`` / ``finished`` against the display-link callback
    /// thread (a single sanctioned lock owned by this DEBUG capture seam).
    let lock = NSLock()

    /// Whether a frame capture is currently in flight on the main thread.
    var inFlight = false
    /// Whether the capture has finished and resumed its continuation.
    var finished = false

    /// Actions to run, keyed by the frame index at which they fire, sorted
    /// ascending by frame. Each is invoked once on the main thread when the
    /// capture reaches its frame.
    public var scheduledActions: [(frame: Int, action: () -> Void)] = []
    /// The index into ``scheduledActions`` of the next action to run.
    public var nextActionIndex: Int = 0

    /// The per-target main-actor samplers. Each returns the live
    /// ``VsyncFrameSample`` for one target at the current frame (the app maps
    /// its `DebugFrameSample` here so this owner stays free of app types).
    public var targets: [@MainActor () -> VsyncFrameSample?] = []

    /// The active display link, retained for the duration of the capture.
    var link: CVDisplayLink?
    /// The continuation resumed once the timeline completes (or fails to start).
    var continuation: CheckedContinuation<Void, Never>?

    /// The total number of frames the timeline captures.
    var frameCount: Int { analyzer.frameCount }
    /// The number of frames ingested so far.
    var framesWritten: Int { analyzer.framesWritten }
    /// The first blank frame seen at/after the close frame, if any.
    var firstBlank: (label: String, frame: Int)? { analyzer.firstBlank }
    /// The first compositor size-mismatch seen at/after the close frame, if any.
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)? { analyzer.firstSizeMismatch }
    /// The per-target per-frame trace lines.
    var trace: [String] { analyzer.trace }

    /// Creates a capture for a timeline of `frameCount` frames whose blank /
    /// size-mismatch detection arms at `closeFrame`.
    public init(frameCount: Int, closeFrame: Int) {
        self.analyzer = VsyncIOSurfaceTimelineAnalyzer(frameCount: frameCount, closeFrame: closeFrame)
    }

    /// Drives the `CVDisplayLink` capture to completion and returns the
    /// analyzer's findings: the first blank frame, the first compositor
    /// size-mismatch, and the full per-frame trace.
    ///
    /// Creates and starts the display link on the main actor, then suspends
    /// until the timeline has ingested all of its frames (or the display link
    /// could not be created).
    @MainActor
    public func run() async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
        let unmanaged = Unmanaged.passRetained(self)
        let ctx = unmanaged.toOpaque()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else {
                self.finish()
                Unmanaged<VsyncIOSurfaceTimelineCapture>.fromOpaque(ctx).release()
                return
            }
            self.link = link

            CVDisplayLinkSetOutputCallback(link, cmuxVsyncIOSurfaceTimelineCallback, ctx)
            CVDisplayLinkStart(link)
        }

        return (firstBlank, firstSizeMismatch, trace)
    }

    /// Tries to claim the single in-flight slot for one frame capture. Returns
    /// `false` (and the callback should skip) if a capture is already in flight
    /// or the timeline has finished.
    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Releases the in-flight slot after a frame capture completes.
    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    /// Marks the capture finished and resumes its continuation exactly once.
    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// `CVDisplayLink` output callback for ``VsyncIOSurfaceTimelineCapture``.
///
/// Sanctioned `@convention(c)` trampoline (C-API requirement): `CVDisplayLink`
/// takes a C function pointer, so this cannot be a method. It recovers the
/// capture from the opaque context, samples one frame on the main thread, and
/// stops the link once the timeline is complete.
fileprivate func cmuxVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineCapture>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            defer { st.endCapture() }
            guard !st.analyzer.isComplete else { return }

            while st.nextActionIndex < st.scheduledActions.count {
                let next = st.scheduledActions[st.nextActionIndex]
                if next.frame != st.framesWritten { break }
                st.nextActionIndex += 1
                next.action()
            }

            let frameSamples: [VsyncFrameSample] = st.targets.compactMap { $0() }
            st.analyzer.ingest(frameSamples: frameSamples)
        }
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineCapture>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
