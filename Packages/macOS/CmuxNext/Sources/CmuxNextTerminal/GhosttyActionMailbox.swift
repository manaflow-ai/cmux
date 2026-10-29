import CmuxNextWakeups

/// The state a surface's Ghostty actions set, one slot each: a later action of a slot replaces the
/// one waiting in it (``GhosttyActionMailbox``).
nonisolated enum GhosttyActionSlot: Int, CaseIterable, Sendable {
    case title, workingDirectory, mouseVisible, rendererHealth, progress, backgroundColor, scrollbar,
         searchTotal, searchSelected

    /// Whether this state waits while nobody sees the terminal (``GhosttyActionMailbox``). The title does
    /// not: it shows outside the terminal (its tab, the sidebar, a remote tab's record), as a background
    /// tab's title still reaches Chrome's tab strip (`WebContentsImpl::UpdateTitle`,
    /// content/browser/web_contents/web_contents_impl.cc).
    var waitsWhileHidden: Bool { self != .title }
}

extension GhosttyAction {
    /// The state this action sets, latest-wins in the surface's mailbox; nil for a discrete action: an
    /// event (a bell, a finished command, an exit), a request (a URL, a search, a config, a host action),
    /// a toggle, or a change the input that caused it must see in its own turn, which runs at once, in
    /// order: a cell size, a key sequence, read-only, and the link and pointer shape under the pointer,
    /// which Ghostty reports inside the move (`ghostty_surface_mouse_pos`) and the press, Cmd-click and
    /// link menu that follow it read (`TerminalLinkPointer`, `pointerMods`).
    nonisolated var mailboxSlot: GhosttyActionSlot? {
        switch self {
        case .setTitle: .title
        case .pwd: .workingDirectory
        case .mouseVisible: .mouseVisible
        case .rendererHealthy: .rendererHealth
        case .progress: .progress
        case .backgroundColor: .backgroundColor
        case .scrollbar: .scrollbar
        case .searchTotal: .searchTotal
        case .searchSelected: .searchSelected
        case .host, .ringBell, .openURL, .mouseShape, .mouseOverLink, .cellSize, .commandFinished, .childExited,
             .secureInput, .readOnly, .keySequence, .configChange, .reloadConfig, .openConfig, .startSearch,
             .endSearch, .copyTitleToClipboard, .render:
            nil
        }
    }

    /// Whether this discrete action runs after the surface's waiting state actions
    /// (``GhosttyActionMailbox/flush()``): every one but a redraw request, which reads and sets no state.
    nonisolated var flushesMailbox: Bool {
        switch self {
        case .render: false
        default: true
        }
    }
}

/// One surface's Ghostty state actions (title, working directory, progress, scrollbar, search counts),
/// applied once per frame of its window, latest wins per ``GhosttyActionSlot``.
/// A streaming program sends a scrollbar and often a title on every app tick; the
/// surface's model now changes once per frame however many came.
///
/// Chrome does the same twice: `Browser::ScheduleUIUpdate` (chrome/browser/ui/browser.cc) keeps one
/// pending set of changes per tab and applies it once, and Blink's `MainThreadEventQueue`
/// (third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc) coalesces continuous
/// input to the next frame while a discrete event first flushes what is queued. A discrete action here
/// calls ``flush()`` and runs in its own turn, so it sees, and keeps its order after, every state
/// action Ghostty sent before it.
///
/// Its ``FrameClient`` is a batch client (it keeps ticking at the stall rate for an occluded window),
/// made with the first action and active only while one waits: an idle surface has no frame client.
/// The client follows the surface's tab node: while nobody sees the terminal, what
/// waits stays held, latest wins per slot, and applies once in the first frame after it shows. A title
/// (``GhosttyActionSlot/waitsWhileHidden``) still applies at the next frame, after what waits before it
/// (a hidden
/// widget gets no BeginFrames in Chrome either: `RenderWidgetHostViewMac::WasOccluded`,
/// content/browser/renderer_host/render_widget_host_view_mac.mm). A discrete action still flushes it at
/// once, so it never runs before the state Ghostty sent before it.
///
/// ```swift
/// let mailbox = GhosttyActionMailbox(owner: "terminal.actions", scheduler: { FrameScheduler.forView(view) },
///                                    node: { tabNode }) { action in
///     _ = view.applyAction(action)
/// }
/// mailbox.post(.scrollbar(bar), in: .scrollbar)   // waits for the frame
/// mailbox.flush()                                  // before a discrete action
/// ```
@MainActor
final class GhosttyActionMailbox {
    /// The frame client's name in the wakeup ledger and debug.wakeups.
    let owner: String
    private let scheduler: @MainActor () -> FrameScheduler
    private let node: @MainActor () -> VisibilityNode?
    private let apply: @MainActor (GhosttyAction) -> Void
    /// The waiting action of each slot, by ``GhosttyActionSlot/rawValue``.
    private var slots = [GhosttyAction?](repeating: nil, count: GhosttyActionSlot.allCases.count)
    /// The filled slots in the order of their latest actions; they apply in this order, so the last
    /// writes of different slots (a working directory, then the title it sets) keep the order Ghostty sent them in.
    private var order: [GhosttyActionSlot] = []
    private var client: FrameClient?
    /// True while the frame client's tick runs: a flush from inside it leaves the client to the tick.
    private var ticking = false

    /// Passes that applied at least one action (a frame or a flush).
    package private(set) var applies = 0
    /// Actions a later one of their slot replaced before they applied.
    package private(set) var replaced = 0

    /// - Parameters:
    ///   - owner: The frame client's name.
    ///   - scheduler: The frame scheduler of the surface's window, read when the client activates.
    ///   - node: The surface's tab node, read when an action is posted: while nobody sees it, what waits
    ///     is held until someone does. Nil: frames apply whether or not anyone sees the surface.
    ///   - apply: Applies one action to the surface (``TerminalSurfaceView/applyAction(_:)``).
    init(owner: String, scheduler: @escaping @MainActor () -> FrameScheduler, node: @escaping @MainActor () -> VisibilityNode? = { nil },
         apply: @escaping @MainActor (GhosttyAction) -> Void) {
        self.owner = owner
        self.scheduler = scheduler
        self.node = node
        self.apply = apply
    }

    /// Actions waiting for the frame (one per filled slot).
    var pendingCount: Int { order.count }

    /// Whether its frame client is active (false whenever nothing waits, after the frame that applied it).
    var isScheduled: Bool { client?.isActive ?? false }

    /// Whether what waits is held because nobody sees the surface's node.
    var isHeld: Bool { client?.isParked ?? false }

    /// Keeps `action`, which sets `slot`, for the next frame, in place of the one waiting in `slot`.
    func post(_ action: GhosttyAction, in slot: GhosttyActionSlot) {
        if slots[slot.rawValue] != nil {
            replaced += 1
            order.removeAll { $0 == slot }
        }
        order.append(slot)
        slots[slot.rawValue] = action
        frameClient().activate()
    }

    /// Applies the waiting actions now, in the order of their latest actions: a discrete action of the
    /// surface calls it first. With nothing left the frame client goes idle.
    func flush() {
        drain()
        if !ticking, order.isEmpty { client?.deactivate() }
    }

    private func tick() -> Bool {
        ticking = true
        defer { ticking = false }
        drain()
        return !order.isEmpty
    }

    /// Applies what waits now; an action posted while they apply waits for the next pass.
    private func drain() {
        guard !order.isEmpty else { return }
        var due: [GhosttyAction] = []
        due.reserveCapacity(order.count)
        for slot in order {
            if let action = slots[slot.rawValue] { due.append(action) }
            slots[slot.rawValue] = nil
        }
        order.removeAll(keepingCapacity: true)
        applies += 1
        for action in due { apply(action) }
    }

    /// The frame client of the surface's current node: a surface moved under another node gets a new one,
    /// and a pass with a slot that does not wait while hidden gets one that ticks whether or not anyone sees it.
    private func frameClient() -> FrameClient {
        let current = order.allSatisfy(\.waitsWhileHidden) ? node() : nil
        if let client, client.visibleOnly === current { return client }
        client?.deactivate()
        // Motion rate: the pointer's visibility and the title follow input.
        // frame-client: a surface's latest-wins Ghostty actions once a frame (view and model state, on main)
        let made = FrameClient(owner: owner, isAnimation: false, rate: .motion, visibleOnly: current, scheduler: scheduler) { [weak self] _ in
            self?.tick() ?? false
        }
        client = made
        return made
    }
}
