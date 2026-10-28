/// The launch mark `launch.visible_terminals_drawn` (bench_launch.py `after-kill`): every terminal on
/// screen when the visible panes loaded (`VisiblePaneRefs.whenShown(_:)`) drew its first frame after its first content.
///
/// A pane counts as loaded when its terminal's first content is queued on the surface's lane, before the parse, the
/// draw and the reveal of a pane held clear; only the frame shows the screen. So each terminal's wait starts when its
/// first content is queued (``contentQueued(_:watch:)``, the session's `whenContentFrameDrawn`), as Chrome times a
/// restored tab from its first contentful paint, not from its load start
/// (components/page_load_metrics/browser/observers/core/uma_page_load_metrics_observer.cc). Terminals are keyed by
/// their session's `ObjectIdentifier`.
///
/// ```swift
/// let drawn = LaunchTerminalsDrawn()
/// TerminalTimings.onContentApplied = { session in
///     drawn.contentQueued(ObjectIdentifier(session)) { session.whenContentFrameDrawn($0) }
/// }
/// paneRefs.whenShown { drawn.whenDrawn(visibleTerminals()) { DebugTimings.markLaunch(LaunchTerminalsDrawn.mark) } }
/// ```
@MainActor
public final class LaunchTerminalsDrawn {
    /// Starts one terminal's wait: runs its argument once at the first frame after the content, returns what cancels it.
    public typealias Watch = (_ drawn: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

    /// The launch mark.
    public nonisolated static let mark = "launch.visible_terminals_drawn"

    private var queued: Set<ObjectIdentifier> = []
    private var drawn: Set<ObjectIdentifier> = []
    private var awaited: Set<ObjectIdentifier>?
    private var done: (@MainActor () -> Void)?
    private var cancels: [@MainActor () -> Void] = []
    /// Once ``whenDrawn(_:_:)`` ran its work, or ``stop()``: no wait starts again.
    public private(set) var isFinished = false

    public init() {}

    /// `key`'s first content was queued: `watch` starts its wait for the first frame drawn after it (once per key).
    public func contentQueued(_ key: ObjectIdentifier, watch: Watch) {
        guard !isFinished, queued.insert(key).inserted else { return }
        if let cancel = watch({ [weak self] in self?.noteDrawn(key) }) { cancels.append(cancel) }
    }

    /// Runs `work` once every terminal in `keys` drew its first content frame. A terminal whose content was never
    /// queued, or whose frame never comes, holds it (the bench's mark timeout ends that run); no terminal on screen
    /// never runs it, since there is no terminal screen to time.
    public func whenDrawn(_ keys: Set<ObjectIdentifier>, _ work: @escaping @MainActor () -> Void) {
        guard !isFinished, done == nil, !keys.isEmpty else { return }
        (awaited, done) = (keys, work)
        finishIfDrawn()
    }

    /// The launch ended without every visible pane loading: no wait starts or ends with the mark.
    public func stop() {
        guard !isFinished else { return }
        isFinished = true
        end()
    }

    private func noteDrawn(_ key: ObjectIdentifier) {
        drawn.insert(key)
        finishIfDrawn()
    }

    private func finishIfDrawn() {
        guard let awaited, let done, awaited.isSubset(of: drawn) else { return }
        isFinished = true
        end()
        done()
    }

    private func end() {
        let cancels = cancels
        (self.cancels, awaited, done, queued, drawn) = ([], nil, nil, [], [])
        for cancel in cancels { cancel() }
    }
}
