import AppKit

// MARK: One attach per frame at a drag's landing

extension CEFLayerHosting {
    /// `CMUX_CEF_LANDING_ATTACH_STAGGER=0` attaches every page a divider drag detached in the landing's own turn, as
    /// before ``landAttach()`` (an A/B run on one build).
    nonisolated static let landingAttachStaggered = ProcessInfo.processInfo.environment["CMUX_CEF_LANDING_ATTACH_STAGGER"] != "0"

    /// A divider drag landed: the page's window comes back. Each attach is a fork call that orders a child window in at
    /// its final place and runs Chromium's window observers, and a drag across many panes detached every page it moved
    /// (s9 browser: 9 detaches at the press, 9 attaches at the landing). All of them in the landing's turn made that one
    /// frame 700-1200 ms (nightly 4ef8b54a0, s9-browser-w30 divider_drag 1202 ms against 120). So in each window the
    /// first landed page attaches now and each other one after the next pass's commit, one per pass
    /// (``CEFLandingAttaches``): every commit of the landing pays at most one attach. A waiting page shows its pixels at
    /// the final size from its hosted context, as it did all drag; it takes no click until its turn (a pass or a few),
    /// and a focus ask brings it back at once (``pageTakesFocus()``). A new motion drops its turn (``landingQueued``),
    /// and a page a drag keeps attached (``dragKeepsAttached``) is not detached, so it queues nothing.
    func landAttach() {
        guard Self.landingAttachStaggered, isDetached, let window = view?.window else { return attach() }
        CEFLandingAttaches.of(window).land(self, afterCommit: afterCommit)
    }

    /// A focus ask on a page waiting its landing turn: it comes back now, for the grant.
    /// - Returns: Whether the page window was detached and came back now.
    func landedTakesFocus() -> Bool {
        landingQueued = false
        guard isDetached else { return false }
        attach()
        return !isDetached
    }

    /// Attaches this page if it still waits its landing turn and nothing else brought it back.
    /// - Returns: Whether it attached (made a fork call).
    fileprivate func attachLanded(first: Bool) -> Bool {
        guard first || landingQueued else { return false }
        landingQueued = false
        guard isDetached, !inResizeMotion else { return false }
        attach()
        return true
    }
}

/// A window's landed pages waiting their attach (``CEFLayerHosting/landAttach()``), oldest first: one attach per pass's
/// commit. Kept on the window, so windows (and tests) never share a turn.
@MainActor
final class CEFLandingAttaches {
    private static var key: UInt8 = 0
    private struct Ref { weak var hosting: CEFLayerHosting? }
    private var waiting: [Ref] = []
    /// An attach ran in this pass; the next waits for its commit.
    private(set) var armed = false
    /// The scheduler of the turn in flight: the first landing's, so one queue waits on one commit source.
    private var afterCommit: CEFLayerHosting.Scheduler?

    static func of(_ window: NSWindow) -> CEFLandingAttaches {
        if let queue = objc_getAssociatedObject(window, &key) as? CEFLandingAttaches { return queue }
        let queue = CEFLandingAttaches()
        objc_setAssociatedObject(window, &key, queue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return queue
    }

    func land(_ hosting: CEFLayerHosting, afterCommit: @escaping CEFLayerHosting.Scheduler) {
        guard armed else {
            armed = true
            _ = hosting.attachLanded(first: true)
            return arm(afterCommit)
        }
        hosting.landingQueued = true
        waiting.append(Ref(hosting: hosting))
    }

    private func arm(_ scheduler: @escaping CEFLayerHosting.Scheduler) {
        afterCommit = scheduler
        scheduler { [weak self] in self?.next() }
    }

    /// Attaches the oldest page still waiting (a new motion, a focus grant, a window change or a closed page took the
    /// others off) and waits for the next commit before the one after it.
    private func next() {
        while !waiting.isEmpty {
            guard let hosting = waiting.removeFirst().hosting, hosting.attachLanded(first: false) else { continue }
            if let afterCommit { return arm(afterCommit) }
        }
        afterCommit = nil
        armed = false
    }
}
