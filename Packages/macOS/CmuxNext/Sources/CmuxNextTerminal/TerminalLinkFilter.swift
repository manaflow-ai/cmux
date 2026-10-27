import AppKit
import CmuxNextCompat
import GhosttyNextKit

/// Whether `text`, detected as a link under a Cmd-hover in a terminal whose shell reported
/// `cwd`, is a link. Runs off the main thread.
public typealias TerminalLinkCheck = @Sendable (_ text: String, _ cwd: String?) -> Bool

/// Which texts under a Cmd-hover are links (cx-do47.1): Ghostty asks through
/// `ghostty_surface_set_link_filter` before it underlines, changes the pointer
/// or opens a regex link, so a path that names no file is plain text. Ghostty
/// asks on its renderer thread and on main with the terminal lock held, so the
/// answer comes from a cache: a text not checked yet is no link while
/// ``TerminalSession/linkCheck`` runs off the main thread, then the pointer
/// position goes to Ghostty again and the underline appears. An answer is
/// kept a few seconds, so a file a program writes after printing its path
/// becomes a link on the next hover. A check started before ``setCheck(_:)`` answers for the
/// check it ran, so its answer is dropped, as Chromium drops a reply bound to a
/// `WeakPtrFactory` that was invalidated (base/memory/weak_ptr.h); the view still hears of it
/// when the new check has not asked about that text, so Ghostty asks again under the new check.
nonisolated final class TerminalLinkFilter: Sendable {
    typealias Check = TerminalLinkCheck
    /// Runs one check off the caller's thread.
    typealias Schedule = @Sendable (_ work: @escaping @Sendable () -> Void) -> Void

    private struct Key: Hashable {
        var text: String
        var cwd: String?
    }

    private struct Answer {
        var isLink: Bool
        var at: ContinuousClock.Instant
    }

    private struct State {
        var check: Check?
        var changed: (@Sendable () -> Void)?
        var cwd: String?
        var answers: [Key: Answer] = [:]
        var pending: Set<Key> = []
        /// Counts ``setCheck(_:)`` calls: a check whose count is not the current one is stale.
        var generation = 0
    }

    static let lifetime: Duration = .seconds(3)
    private static let capacity = 512
    private let state = Mutex(State())
    private let schedule: Schedule

    /// The checks run on this filter's own concurrent queue; a test passes its own `schedule` to run them itself.
    init(schedule: @escaping Schedule = TerminalLinkFilter.ownQueue()) {
        self.schedule = schedule
    }

    /// A named concurrent queue per filter (per surface), at the QoS of a person waiting on the pointer. A check
    /// is a stat that can hang on a sleeping disk or a network mount, so the checks run side by side: one stalled
    /// check holds no later one, in this terminal or another. A concurrent queue targets GCD's width-limited root
    /// queue, as the unnamed root queue these checks used before, so a burst of stalled checks parks no more threads.
    static func ownQueue() -> Schedule {
        let queue = DispatchQueue(label: "com.cmuxterm.next.terminal.link-check", qos: .userInitiated, attributes: .concurrent)
        return { work in queue.async(execute: work) }
    }

    /// `changed` runs on any thread after an answer changed (the view sends the pointer again).
    func onChange(_ changed: @escaping @Sendable () -> Void) {
        state.withLock { $0.changed = changed }
    }

    /// Nil asks nothing: every regex link is a link, as without the filter.
    func setCheck(_ check: Check?) {
        state.withLock {
            $0.check = check
            $0.generation += 1
            $0.answers.removeAll()
            $0.pending.removeAll()
        }
    }

    /// The folder the shell last reported. The surface view sets it on each pwd report and
    /// when a session swaps in a fresh surface; every ask uses the last one.
    func setWorkingDirectory(_ cwd: String?) {
        state.withLock { $0.cwd = cwd }
    }

    /// The folder asks use now (``setWorkingDirectory(_:)``).
    var workingDirectory: String? { state.withLock { $0.cwd } }

    /// The cached answer for `text`; starts a check when there is none or it is old.
    func isLink(_ text: String) -> Bool {
        let now = ContinuousClock.now
        let (answer, start): (Bool, (Key, Check, Int)?) = state.withLock { state in
            guard let check = state.check else { return (true, nil) }
            let key = Key(text: text, cwd: state.cwd)
            let known = state.answers[key]
            if let known, known.at.duration(to: now) < Self.lifetime { return (known.isLink, nil) }
            guard state.pending.insert(key).inserted else { return (known?.isLink ?? false, nil) }
            return (known?.isLink ?? false, (key, check, state.generation))
        }
        if let start {
            let (key, check, generation) = start
            schedule { [self] in
                let isLink = check(key.text, key.cwd)
                let changed: (@Sendable () -> Void)? = state.withLock { state in
                    guard state.generation == generation else {
                        let unasked = state.answers[key] == nil && !state.pending.contains(key)
                        return unasked ? state.changed : nil
                    }
                    let before = state.answers[key]?.isLink
                    if state.answers.count >= Self.capacity { state.answers.removeAll() }
                    state.answers[key] = Answer(isLink: isLink, at: .now)
                    state.pending.remove(key)
                    return (before ?? false) == isLink ? nil : state.changed
                }
                changed?()
            }
        }
        return answer
    }
}

/// `ghostty_surface_link_filter_cb`: userdata is the surface's ``SurfaceBridge``.
nonisolated func ghosttyLinkFilter(_ userdata: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?, _ length: UInt) -> Bool {
    // SAFETY: the bridge registered as this callback's userdata (installLinkFilter), alive past
    // the surface (SurfaceBridge.from); Ghostty passes `length` bytes, valid for this callback,
    // which String(decoding:) copies.
    guard let bridge = unsafe SurfaceBridge.from(userdata), let text = unsafe text else { return true }
    // The folder comes from the view, which pushes it on every pwd report and surface swap.
    // SAFETY: as above.
    let bytes = unsafe UnsafeRawBufferPointer(start: UnsafeRawPointer(text), count: Int(length))
    // SAFETY: as above.
    return bridge.linkFilter.isLink(unsafe String(decoding: bytes, as: UTF8.self))
}

extension SurfaceBridge {
    /// Hands Ghostty this surface's link filter, asking `check` (nil: every regex link is one).
    @MainActor func installLinkFilter(_ check: TerminalLinkCheck?) {
        linkFilter.setCheck(check)
        guard let view, let surface = view.surface else { return }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface); the userdata is this
        // bridge as the view retained it for every surface callback (TerminalSurfaceView.bridge,
        // released only after ghostty_surface_free), and the callback has the C signature ghostty.h declares.
        unsafe ghostty_surface_set_link_filter(surface, ghosttyLinkFilter, view.bridge.toOpaque())
    }

    /// The pointer's position again, with the keys held now: a link filter answer that
    /// arrived after the move shows (or hides) its underline without another move.
    @MainActor func sendPointerAgain() {
        view?.linkPointer.refresh()
    }
}
