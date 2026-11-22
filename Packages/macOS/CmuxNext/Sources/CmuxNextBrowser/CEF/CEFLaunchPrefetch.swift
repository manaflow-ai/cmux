import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation

/// Chromium's framework for a relaunch whose last quit left a Chromium page on screen (a restored agent chat): read
/// into the file cache from the app's `main`, before any window or engine exists, and `CefInitialize` let through
/// before the first frame instead of after it. The restored page asks for its Chromium tab as the launch window builds
/// and waits on both before `agent_pane.painted`: on a cold file cache (every update relaunch) the framework read alone
/// took about 2 s (``CEFFrameworkPrefetch``), and the first-frame gate (CMUX-571) held `CefInitialize` behind the frame
/// that page is part of.
///
/// Only the read and the gate's choice change. No Chromium code runs here; `CefInitialize` still runs on the main
/// thread when the page (or the warm start) asks, and a launch whose last quit saved no page does nothing new and
/// keeps the first-frame gate.
///
/// ```swift
/// let chromium = CEFLaunchPrefetch()
/// chromium.start(on: work) { savedPagesExist() }                       // in main
/// cef.initializeAfter(chromium.initializeGate(firstFrame))             // once the engine exists
/// ```
public nonisolated final class CEFLaunchPrefetch: Sendable {
    // concurrency-allow: a short critical section over one optional flag, written once by the lane thread and read
    // once by the main thread, with no I/O under it.
    private let restoresPage = Mutex<Bool?>(nil)
    private let locate: @Sendable () -> CEFRuntimeLayout?
    private let read: @Sendable (CEFRuntimeLayout) -> Void

    /// The app's embedded runtime (``CEFRuntimeLayout/locate(bundle:environment:fileManager:)``), read with
    /// ``CEFFrameworkPrefetch/readBinary(_:)``.
    public convenience init() {
        self.init(locate: { CEFRuntimeLayout.locate() }, read: { CEFFrameworkPrefetch.readBinary($0) })
    }

    /// - Parameters:
    ///   - locate: Finds the runtime. Tests pass spies.
    ///   - read: Reads its binary into the file cache. Tests pass spies.
    init(locate: @escaping @Sendable () -> CEFRuntimeLayout?, read: @escaping @Sendable (CEFRuntimeLayout) -> Void) {
        self.locate = locate
        self.read = read
    }

    /// On `work`'s files lane at ``WorkPriority/userVisible`` (its own serial slot, beside the launch snapshot and the
    /// saved pages' reads at user-blocking): asks `likely` whether the last quit left a page on screen, records the
    /// answer for ``initializeGate(_:)``, and when it did, finds the runtime and reads its framework binary into the
    /// file cache.
    public func start(on work: BackgroundWork, when likely: @escaping @Sendable () -> Bool) {
        work.post(.userVisible, mayBlock: .files) { [self] in
            let likely = likely()
            restoresPage.withLock { $0 = likely }
            guard likely, let layout = locate() else { return }
            read(layout)
        }
    }

    /// What `CEFEngine.initializeAfter` gets: nil (`CefInitialize` at once) when the last quit left a page on screen,
    /// since that page is part of the first frame; `firstFrame` when it did not, or when the lane has not answered yet
    /// (the base behaviour).
    @MainActor
    public func initializeGate(_ firstFrame: FirstFrameGate) -> FirstFrameGate? {
        restoresPage.withLock { $0 } == true ? nil : firstFrame
    }
}
