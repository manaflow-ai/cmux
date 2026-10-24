/// Makes cmux pages' CEF tabs one per display frame, never in the frame of the action that showed
/// them (perf-lead.md F3, section 5).
///
/// A cmux page in Chromium starts on its first show (PageWebView+ChromiumCost.swift). A workspace
/// or tab switch that shows N pages that never showed asked for N CEF tabs in its own turn:
/// `makeReadyTab` and `createBrowser` run on the main thread (the CEF UI thread), ahead of the
/// switch's commit, so the switch frame paid N cold starts. Each start now waits for the start of
/// a later display frame and takes that frame alone; the next start waits for the frame after.
/// The action commits without any of them, and no frame makes more than one. The incoming page's
/// paint hold keeps the outgoing content until it paints, so a start costs about one frame of
/// first-paint latency against its load and React mount. The same rule as the App's
/// `ContentPresentationScheduler` one new terminal surface per frame (architecture.md 5a).
/// Not a delay: a start waits only for the next frame its turn gets, and an idle app has no frame
/// wakeups (the App's display-frame batcher).
///
/// ```swift
/// let frames = FrameBatcher(owner: "ChromiumPageStart")
/// let budget = ChromiumPageFrameBudget(scheduleFrame: frames.scheduleFrame)
/// await budget.nextFrame() // then make the CEF tab
/// ```
@MainActor
public final class ChromiumPageFrameBudget {
    /// Asks for one main-actor callback at the start of the next display frame.
    public typealias ScheduleFrame = @MainActor (_ work: @escaping @MainActor @Sendable () -> Void) -> Void

    private let scheduleFrame: ScheduleFrame
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var scheduled = false

    /// - Parameter scheduleFrame: The display frames (the App's frame batcher; a test passes frames
    ///   it steps by hand).
    public init(scheduleFrame: @escaping ScheduleFrame) {
        self.scheduleFrame = scheduleFrame
    }

    /// Pages waiting for their frame (tests, `debug.cef`).
    public var waitingCount: Int { waiting.count }

    /// Returns at the start of a display frame that no other page start takes.
    public func nextFrame() async {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            schedule()
        }
    }

    private func schedule() {
        guard !scheduled, !waiting.isEmpty else { return }
        scheduled = true
        // Holds self: a waiting start is resumed even if the host let go meanwhile.
        scheduleFrame { [self] in
            scheduled = false
            waiting.removeFirst().resume()
            schedule()
        }
    }
}
