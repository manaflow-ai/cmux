public import CmuxNextDaemon
public import CmuxNextWakeups

/// The next Cmd-N's workspace view, made before the key (STATUS 15250), as Chrome makes its next tab's renderer
/// ahead and the key only swaps: one per window, in its own slot (never a parked workspace or a saved record).
///
/// ``fill()`` makes it after the frame commits, in three background tasks on the app's scheduler (each yields to the
/// person's input and runs only in a frame with idle time, so none lands in the late frames after a switch; none holds
/// the main thread longer than one step): the daemon's reserved workspace (`reserve`), its
/// view on that model (`build`, unmounted), then its window entry (`mount`, hidden and parked). A key's show takes it
/// (``take(_:)``) and builds nothing. A view whose workspace is no longer the reservation (`isReserved`) goes at the next
/// fill; ``drop()`` lets it go now (another window became key, the window closes, memory pressure). Each step runs only
/// while its workspace is still the reservation: a key that took it between steps leaves the later steps nothing to do,
/// and a key that comes between the build and the mount takes the built view and mounts it in its own turn.
///
/// ```swift
/// let spare = WorkspaceSpareSlot<Content>(owner: "WorkspaceSpare", on: mainWork, wanted: { isKeyWindow },
///     reserve: { store.reservedWorkspace?.model }, build: { Content($0) }, mount: { host.addHidden($0) },
///     teardown: { $0.teardown() }, workspace: { $0.workspace }, isReserved: { store.reserves($0) })
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
    private let workspace: @MainActor (Content) -> WorkspaceModel
    private let isReserved: @MainActor (WorkspaceModel) -> Bool
    /// The view made and mounted, waiting for its key.
    public private(set) var ready: Content?
    /// The view built and not mounted yet (between the build and the mount steps).
    private var built: Content?
    /// The fill under way (``drop()`` moves past it, so its later steps do nothing).
    private var making: UInt64?
    /// Whether a fill is under way (a step of it still to run): false once the slot settled.
    var isFilling: Bool { making != nil }
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - wanted: whether this slot may hold a view now (its window is the key main window, the daemon is up).
    ///   - reserve: the daemon's reserved workspace, reserved now if it has none; nil: none can be.
    ///   - build: the view on that workspace, not in a window yet.
    ///   - mount: puts the view in its window, hidden and parked.
    ///   - teardown: lets a view go (out of its window).
    ///   - workspace: the view's workspace.
    ///   - isReserved: whether a workspace is still the daemon's reservation.
    public convenience init(owner: String, on work: MainWorkScheduler, wanted: @escaping @MainActor () -> Bool,
                reserve: @escaping @MainActor () -> WorkspaceModel?, build: @escaping @MainActor (WorkspaceModel) -> Content?,
                mount: @escaping @MainActor (Content) -> Void, teardown: @escaping @MainActor (Content) -> Void,
                workspace: @escaping @MainActor (Content) -> WorkspaceModel, isReserved: @escaping @MainActor (WorkspaceModel) -> Bool) {
        let queue = FrameBatchQueue(owner: owner, budgeted: .background, on: work)
        self.init(enqueue: { queue.enqueue($0) }, wanted: wanted, reserve: reserve, build: build, mount: mount, teardown: teardown, workspace: workspace, isReserved: isReserved)
    }

    init(enqueue: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void, wanted: @escaping @MainActor () -> Bool,
         reserve: @escaping @MainActor () -> WorkspaceModel?, build: @escaping @MainActor (WorkspaceModel) -> Content?,
         mount: @escaping @MainActor (Content) -> Void, teardown: @escaping @MainActor (Content) -> Void,
         workspace: @escaping @MainActor (Content) -> WorkspaceModel, isReserved: @escaping @MainActor (WorkspaceModel) -> Bool) {
        self.enqueue = enqueue
        self.wanted = wanted
        self.reserve = reserve
        self.build = build
        self.mount = mount
        self.teardown = teardown
        self.workspace = workspace
        self.isReserved = isReserved
    }

    // Generic main-actor class: no isolated deinit (swift-frontend 6.3.3 crashes on one in -O; check-concurrency).
    nonisolated deinit {}

    /// The view when `matches` (the workspace the key shows), out of the slot; nil makes nothing. One built and not yet
    /// mounted is mounted now (its fill stops), so the key never builds a second view of the same workspace.
    public func take(_ matches: (Content) -> Bool) -> Content? {
        if let ready, matches(ready) {
            self.ready = nil
            return ready
        }
        guard let built, matches(built) else { return nil }
        stop()
        mount(built)
        return built
    }

    /// Lets the ready view go, and stops a fill under way (a view it built goes too).
    public func drop() {
        let views = [ready, built].compactMap { $0 }
        (ready, built) = (nil, nil)
        stop()
        views.forEach(teardown)
    }

    private func stop() {
        generation &+= 1
        making = nil
        built = nil
    }

    /// After this frame commits: a stale ready view goes, and a new one is made in three background steps when none is.
    /// `others`: the other windows' slots, whose views go then (one key main window holds the view, as the New Tab spare).
    public func fill(dropping others: @escaping @MainActor () -> [WorkspaceSpareSlot] = { [] }) {
        AfterFrameCommit().run { [weak self] in
            guard let self else { return }
            for other in others() where other !== self { other.drop() }
            start()
        }
    }

    /// ``fill()``'s work, after the frame commit.
    func start() {
        if let ready, !isReserved(workspace(ready)) { drop() }
        guard ready == nil, making == nil, wanted() else { return }
        let run = generation
        making = run
        step(run) { [weak self] in
            guard let self else { return }
            guard let model = reserve() else { return finish(run) }
            step(run) { [weak self] in
                guard let self else { return }
                guard isReserved(model), let content = build(model) else { return finish(run) }
                built = content
                step(run, orElse: { [weak self] in self?.dropBuilt(content) }) { [weak self] in
                    guard let self else { return }
                    finish(run)
                    built = nil
                    guard isReserved(model) else { return teardown(content) }
                    mount(content)
                    ready = content
                }
            }
        }
    }

    /// A fill that stopped after its build: its view goes, unless a key took it.
    private func dropBuilt(_ content: Content) {
        guard built === content else { return }
        built = nil
        teardown(content)
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
