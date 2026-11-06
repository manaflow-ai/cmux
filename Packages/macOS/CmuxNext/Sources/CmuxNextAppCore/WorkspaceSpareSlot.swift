public import CmuxNextDaemon
public import CmuxNextWakeups

/// The next Cmd-N's workspace view, made before the key (STATUS 15250), as Chrome makes its next tab's renderer
/// ahead and the key only swaps: one per window, in its own slot (never a parked workspace or a saved record).
///
/// ``fill()`` makes it after the frame commits, in three background tasks on the app's scheduler (each yields to the
/// person's input; none holds the main thread longer than one step): the daemon's reserved workspace (`reserve`), its
/// view on that model (`build`, unmounted), then its window entry (`mount`, hidden and parked). A key's show takes it
/// (``take(_:)``) and builds nothing. A view whose workspace is no longer the reservation (`isCurrent`) goes at the next
/// fill; ``drop()`` lets it go now (another window became key, the window closes, memory pressure).
///
/// ```swift
/// let spare = WorkspaceSpareSlot<Content>(owner: "WorkspaceSpare", on: mainWork, wanted: { isKeyWindow },
///     reserve: { store.reservedWorkspace?.model }, build: { Content($0) }, mount: { host.addHidden($0) },
///     teardown: { $0.teardown() }, isCurrent: { store.reserves($0.workspace) })
/// let content = spare.take { $0.workspace === shown } ?? Content(shown) // the key's turn
/// ```
@MainActor
public final class WorkspaceSpareSlot<Content: AnyObject> {
    /// Runs one step as its own background task (the app's scheduler; a test's own queue).
    private let enqueue: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let wanted: @MainActor () -> Bool
    private let reserve: @MainActor () -> WorkspaceModel?
    private let build: @MainActor (WorkspaceModel) -> Content?
    private let mount: @MainActor (Content) -> Void
    private let teardown: @MainActor (Content) -> Void
    private let isCurrent: @MainActor (Content) -> Bool
    /// The view made and mounted, waiting for its key.
    public private(set) var ready: Content?
    /// The fill under way (``drop()`` moves past it, so its later steps do nothing).
    private var making: UInt64?
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - wanted: whether this slot may hold a view now (its window is the key main window, the daemon is up).
    ///   - reserve: the daemon's reserved workspace, reserved now if it has none; nil: none can be.
    ///   - build: the view on that workspace, not in a window yet.
    ///   - mount: puts the view in its window, hidden and parked.
    ///   - teardown: lets a view go (out of its window).
    ///   - isCurrent: whether the view's workspace is still the daemon's reservation.
    public init(owner: String, on work: MainWorkScheduler, wanted: @escaping @MainActor () -> Bool,
                reserve: @escaping @MainActor () -> WorkspaceModel?, build: @escaping @MainActor (WorkspaceModel) -> Content?,
                mount: @escaping @MainActor (Content) -> Void, teardown: @escaping @MainActor (Content) -> Void,
                isCurrent: @escaping @MainActor (Content) -> Bool) {
        let queue = FrameBatchQueue(owner: owner, budgeted: .background, on: work)
        self.init(enqueue: { queue.enqueue($0) }, wanted: wanted, reserve: reserve, build: build, mount: mount, teardown: teardown, isCurrent: isCurrent)
    }

    init(enqueue: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void, wanted: @escaping @MainActor () -> Bool,
         reserve: @escaping @MainActor () -> WorkspaceModel?, build: @escaping @MainActor (WorkspaceModel) -> Content?,
         mount: @escaping @MainActor (Content) -> Void, teardown: @escaping @MainActor (Content) -> Void,
         isCurrent: @escaping @MainActor (Content) -> Bool) {
        self.enqueue = enqueue
        self.wanted = wanted
        self.reserve = reserve
        self.build = build
        self.mount = mount
        self.teardown = teardown
        self.isCurrent = isCurrent
    }

    // Generic main-actor class: no isolated deinit (swift-frontend 6.3.3 crashes on one in -O; check-concurrency).
    nonisolated deinit {}

    /// The ready view when `matches` (the workspace the key shows), out of the slot; nil makes nothing.
    public func take(_ matches: (Content) -> Bool) -> Content? {
        guard let ready, matches(ready) else { return nil }
        self.ready = nil
        return ready
    }

    /// Lets the ready view go, and stops a fill under way.
    public func drop() {
        generation &+= 1
        making = nil
        if let ready {
            self.ready = nil
            teardown(ready)
        }
    }

    /// After this frame commits: a stale ready view goes, and a new one is made in three background steps when none is.
    public func fill() {
        AfterFrameCommit().run { [weak self] in self?.start() }
    }

    /// ``fill()``'s work, after the frame commit.
    func start() {
        if let ready, !isCurrent(ready) { drop() }
        guard ready == nil, making == nil, wanted() else { return }
        let run = generation
        making = run
        step(run) { [weak self] in
            guard let self else { return }
            guard let model = reserve() else { return finish(run) }
            step(run) { [weak self] in
                guard let self else { return }
                guard let content = build(model) else { return finish(run) }
                step(run, orElse: { [weak self] in self?.teardown(content) }) { [weak self] in
                    guard let self else { return }
                    finish(run)
                    guard isCurrent(content) else { return teardown(content) }
                    mount(content)
                    ready = content
                }
            }
        }
    }

    /// Runs `work` as its own background task while fill `run` is current and the slot is wanted; else `orElse`.
    private func step(_ run: UInt64, orElse: @escaping @MainActor () -> Void = {}, _ work: @escaping @MainActor () -> Void) {
        enqueue { [weak self] in
            guard let self, generation == run, making == run, wanted() else {
                self?.finish(run)
                return orElse()
            }
            work()
        }
    }

    private func finish(_ run: UInt64) {
        if making == run { making = nil }
    }
}
