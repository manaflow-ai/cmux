import AppKit
import CmuxNextRemoteLayer
import Darwin

/// One Core Animation fence per geometry transaction that resizes Chromium pages (a divider drag
/// event, a step of the window's live resize, a spring start): every page resized in the
/// transaction gets the same fence (fork `cmux_browser_set_resize_fence`), the window context that
/// shows it holds its commit on it, and the app drops its own send right once the transaction
/// committed. The render server then shows cmux's frame and each page's first frame at the new size
/// together, or cmux's alone after the deadline; the main thread never waits.
///
/// Chrome's form of the same sync is the surface deadline (`cc/layers/deadline_policy.h`
/// `UseSpecifiedDeadline(frames)`, `components/viz/service/surfaces/surface.h`); its macOS
/// window resize instead pumps the UI thread inside the commit
/// (`ui/accelerated_widget_mac/ca_transaction_observer.mm`, `CATransactionCoordinator`), which
/// cmux does not copy. The fence port is WebKit's form (`-[CAContext setFencePort:]`).
///
/// The runtime owns one; tests drive it through ``Commit`` without a render server.
final class CEFResizeFences {
    /// How many display frames a page may hold the transaction for its frame at the new size
    /// (DeadlinePolicy semantics: then cmux's frame shows without it).
    static let deadlineFrames: UInt32 = 2

    /// A Core Animation context that commits a window's layer tree.
    struct Context {
        /// The context's identity: it holds a transaction's commit once.
        let id: ObjectIdentifier
        /// A new fence port with one send right for the caller; 0 when none could be made.
        let createFence: () -> mach_port_t
        /// The context's next commit waits for `fence`.
        let holdCommit: (_ fence: mach_port_t) -> Void
    }

    /// The Core Animation calls a fence needs: a seam, so tests count fences and releases.
    struct Commit {
        /// The context that commits `view`'s layer tree (its window's); nil outside a window.
        let context: (NSView) -> Context?
        /// Runs `block` once after the current transaction committed. False when the handler
        /// was not added (the transaction is past that phase): `block` never runs.
        let afterCommit: (_ block: @escaping @MainActor () -> Void) -> Bool
        /// Drops the app's send right to `fence`.
        let release: (_ fence: mach_port_t) -> Void

        /// QuartzCore's: the layer's `CAContext`, a post-commit handler of the current
        /// `CATransaction`, and `mach_port_deallocate`.
        static let quartzCore = Commit(
            context: { view in
                guard let context = view.layer?.context() else { return nil }
                return Context(id: ObjectIdentifier(context),
                               createFence: { context.createFencePort() },
                               holdCommit: { context.setFencePort($0) })
            },
            afterCommit: { block in
                // The SDK's API notes import the SPI selector `addCommitHandler:forPhase:` as `addCommitHandler(_:for:)`.
                CATransaction.addCommitHandler({
                    // main-proof: CATransaction runs a main-thread transaction's commit handlers on the main thread
                    MainActor.assumeIsolated { block() }
                }, for: kCATransactionPhasePostCommit)
            },
            release: { fence in _ = mach_port_deallocate(mach_task_self_, fence) })
    }

    /// The fork's call: true when it took its own send right to the fence for the page's next GPU
    /// commit at the new size (false for a closed browser's id). It drops that right when the
    /// commit lands, at the deadline, and when the browser closes or its GPU process dies.
    typealias SetFence = (_ browser: Int32, _ fence: mach_port_t, _ deadlineFrames: UInt32) -> Bool

    private struct Transaction {
        let fence: mach_port_t
        /// The contexts whose commit already waits for `fence`.
        var holding: Set<ObjectIdentifier> = []
        /// The browsers whose page window took `fence` (a layout may resize a view more than once).
        var pages: Set<Int32> = []
    }

    private let commit: Commit
    /// The fence of the transaction still open, until it committed.
    private var open: Transaction?
    /// Fences made so far: one per transaction that resized a page.
    private(set) var fencesMade = 0
    /// Fences the app released its right to so far.
    private(set) var fencesReleased = 0
    /// Pages that took a transaction's fence so far.
    private(set) var joins = 0

    init(commit: Commit = .quartzCore) {
        self.commit = commit
    }

    /// The page window of `browser` over `view` resizes in this transaction: its next frame at the
    /// new size and the transaction's commit of `view`'s window show together. The first page of
    /// a transaction makes its fence; a page joins a transaction once. True when the page has it.
    @discardableResult
    func join(_ view: NSView, browser: Int32, setFence: SetFence) -> Bool { // perf-hot: 0.05ms cef-geometry (each resized page)
        guard let context = commit.context(view) else { return false }
        if open?.pages.contains(browser) == true { return true }
        guard let fence = currentFence(made: context) else { return false }
        guard setFence(browser, fence, Self.deadlineFrames) else { return false }
        joins += 1
        open?.pages.insert(browser)
        if open?.holding.insert(context.id).inserted == true { context.holdCommit(fence) }
        return true
    }

    /// The open transaction's fence, made by `context` when none is open. The app's own right goes
    /// after the commit on every path: the handler holds the port, not this object. When the
    /// transaction takes no handler, the right goes at once and this resize joins nothing, so no
    /// commit waits on a fence the app keeps.
    private func currentFence(made context: Context) -> mach_port_t? {
        if let open { return open.fence }
        let fence = context.createFence()
        guard fence != 0 else { return nil }
        fencesMade += 1
        let release = commit.release
        let added = commit.afterCommit { [weak self] in
            release(fence)
            self?.closed(fence)
        }
        guard added else {
            release(fence)
            fencesReleased += 1
            return nil
        }
        open = Transaction(fence: fence)
        return fence
    }

    private func closed(_ fence: mach_port_t) {
        fencesReleased += 1
        if open?.fence == fence { open = nil }
    }
}
