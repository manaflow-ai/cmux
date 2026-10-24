/// Makes cmux pages' Chromium pages one per display frame, never in the frame of the action that
/// showed them (perf-lead.md F3, section 5).
///
/// A cmux page in Chromium starts on its first show (PageWebView+ChromiumCost.swift). A workspace
/// or tab switch that shows N pages that never showed asked for N CEF tabs in its own turn:
/// `makeReadyTab` and `createBrowser` run on the main thread (the CEF UI thread), ahead of the
/// switch's commit, so the switch frame paid N cold starts. The app's Chromium page host makes each
/// start wait for the start of a later display frame and take that frame alone; the next start
/// waits for the frame after. The action commits without any of them, and no frame makes more than
/// one. The same rule as the app's one new terminal surface per frame (architecture.md 5a).
/// Not a delay: a start waits only for the next frame its turn gets, and an idle app has no frame
/// wakeups (the app passes a frame batcher that runs only while work waits).
///
/// Not the root fix, and not measured yet: this spreads the starts, it does not remove them. The
/// cost of one start on the main thread (light and STRESS) is not measured; if one start does not
/// fit in a frame, a switch that shows N never-shown pages drops a frame N times in a row, and the
/// N-th page paints N frames late. The fix that removes the cost is a page taken from a pre-made
/// CEF tab (the CEFSpareWindow / ChromiumWarmup path, owned by PL-cef-tab), or a start before a
/// likely show (hover, preselect). Keep this spread only with a measured start time that fits in a
/// frame, written here.
///
/// ```swift
/// let budget = ChromiumPageFrameBudget(requestFrame: FrameBatcher(owner: "ChromiumPageStart").scheduleFrame)
/// await budget.nextFrame() // then make the CEF tab
/// ```
@MainActor
public final class ChromiumPageFrameBudget {
    /// Asks for one main-actor callback at the start of a later display frame.
    public typealias FrameRequest = @MainActor (_ work: @escaping @MainActor @Sendable () -> Void) -> Void

    private let requestFrame: FrameRequest
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var scheduled = false

    /// - Parameter requestFrame: The display frames: the app's frame batcher, which ticks only
    ///   while a start waits; a test passes one it steps by hand.
    public init(requestFrame: @escaping FrameRequest) {
        self.requestFrame = requestFrame
    }

    /// Pages waiting for their frame (tests).
    var waitingCount: Int { waiting.count }

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
        requestFrame { [self] in
            scheduled = false
            waiting.removeFirst().resume()
            schedule()
        }
    }
}
