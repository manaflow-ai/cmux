public import AppKit
import CmuxNextPages
import CmuxNextWakeups

/// The app's last New Tab page frames (cx-ec99), one per pane size: a New Tab page that has not
/// painted draws the one at its size, so Cmd-T never shows an empty pane. Each size keeps its own,
/// so a split pane's frame never replaces the whole area's that Cmd-N's new workspace shows (Leo
/// 2026-10-20: the page shifted in a new workspace opened from a split one). They are kept with
/// what they show: a change of the chat list or of the picked model drops them (and every page's
/// own remembered frame, `AgentPageRedraw`), so no page ever draws old chats or an old model; a
/// frame's size and appearance must match the pane's, so a pane with no size yet draws none.
@MainActor
public final class AgentPaneNewTabFrame {
    public static let shared = AgentPaneNewTabFrame()

    /// What the frame shows besides its size and appearance.
    public struct Content: Equatable, Sendable {
        /// The first page of the chat list (its hash).
        public var chats: Int?
        /// The picked agent and model.
        public var model: String?
    }

    public private(set) var content = Content()
    /// Bumped on every content change: a frame from an older generation shows old content.
    public private(set) var generation: UInt64 = 0
    private var frames: [(image: NSImage, size: CGSize, appearance: NSAppearance.Name?, generation: UInt64)] = []
    /// Frames kept: the sizes of a split workspace's panes and of the whole area.
    static let sizes = 4

    public init() {}

    /// The frame drawn at `size` and `appearance`, with today's content. None for a pane not laid out yet (a zero
    /// size): it has no size to pick a frame by, and the newest frame of any size drew a split pane's page top-left
    /// in a new workspace's whole area until its page painted (Lawrence 2026-11-19: Cmd-N's page shifted). Its page
    /// asks again at the layout that gives it a size (``AgentPageRedraw/askPictureAtNewSize(of:)``).
    public func image(size: CGSize, appearance: NSAppearance.Name?) -> NSImage? {
        guard size != .zero else { return nil }
        return frames.last { $0.generation == generation && $0.appearance == appearance && size == $0.size }?.image
    }

    /// Keeps `image` as the frame at `size` and `appearance`, the newest one.
    func store(_ image: NSImage, size: CGSize, appearance: NSAppearance.Name?, generation: UInt64) {
        frames.removeAll { $0.size == size && $0.appearance == appearance }
        frames.append((image, size, appearance, generation))
        if frames.count > Self.sizes { frames.removeFirst(frames.count - Self.sizes) }
    }

    /// What one page draws: the chat list and model it last drew, and how many answers it got.
    private struct Page {
        weak var model: AgentPaneModel?
        var chats: Int?
        var picked: String?
        var answers = 0
    }
    private var pages: [ObjectIdentifier: Page] = [:]

    /// A page model was made: it draws the model picked now (its New Tab payload's last picks).
    public func pageMade(_ model: AgentPaneModel) {
        pages = pages.filter { $0.value.model != nil }
        pages[ObjectIdentifier(model)] = Page(model: model, chats: nil, picked: content.model)
    }

    /// `model`'s page draws today's chat list and model.
    func shows(_ model: AgentPaneModel) -> (Bool, answers: Int) {
        guard let page = pages[ObjectIdentifier(model)] else { return (false, 0) }
        return ((content.chats == nil || page.chats == content.chats) && page.picked == content.model, page.answers)
    }

    /// `view` (a New Tab page in `host`) 400 ms after it painted (its chats and chips in), clear
    /// areas left clear: what the next New Tab page draws until it paints. Only when no frame with
    /// today's content, size and appearance is held, and the page draws today's content (it drew an
    /// answer one page frame before the capture, and none came meanwhile); one capture per page at a
    /// time, never of a hidden page (perf-tabs I6).
    public func capture(_ view: AgentPaneView, in host: NSView) {
        let redraw = view.redraw
        guard !redraw.givesNewTabFrame else { return }
        redraw.givesNewTabFrame = true
        view.model.whenPainted { [weak self, weak view, weak host, weak redraw] in
            let settle = DemandTimer(owner: "newTab.frame.settle")
            settle.schedule(after: .milliseconds(400)) { @MainActor in
                withExtendedLifetime(settle) {}
                defer { redraw?.givesNewTabFrame = false }
                guard let self, let view, let host, let redraw, view.model.newTab != nil, !view.pageDrawsOverCovers, view.isDescendant(of: host),
                      view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
                let size = host.bounds.size, appearance = host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                let takenAt = self.generation, before = self.shows(view.model)
                guard size != .zero, before.0, self.image(size: size, appearance: appearance) == nil else { return }
                // One page frame first: an answer handed to the page before this is drawn by then.
                await withCheckedContinuation { done in redraw.afterNextFrame { done.resume() } }
                guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.isDescendant(of: host), host.bounds.size == size,
                      let snapshot = await redraw.snapshot(), snapshot.size == size, view.snapshotKeepsClearAreas,
                      takenAt == self.generation, self.shows(view.model) == before else { return }
                self.store(snapshot, size: size, appearance: appearance, generation: takenAt)
            }
        }
    }

    /// The chat list answer `model`'s page asked for (`chats.page`). The first page (no cursor, no
    /// search) sets the list: a chat's key, title, folder and time, and the row design, which the page
    /// draws; other fields (a streamed preview) move nothing.
    func chatsAnswered(_ answer: AgentPaneChatsPage, query: AgentPaneChatsQuery, to model: AgentPaneModel) {
        let key = ObjectIdentifier(model)
        pages[key, default: Page(model: model)].answers += 1
        guard query.cursor == nil, query.text?.isEmpty ?? true else { return }
        var hasher = Hasher()
        for chat in answer.chats { hasher.combine(chat.id); hasher.combine(chat.title); hasher.combine(chat.cwd); hasher.combine(chat.updatedAt) }
        hasher.combine(answer.design); hasher.combine(answer.ready); hasher.combine(answer.enabled)
        let drawn = hasher.finalize()
        pages[key]?.chats = drawn
        update(\.chats, drawn)
    }

    /// `model`'s New Tab page picked an agent or model (or dismissed the harness hint).
    public func modelChanged(_ pick: AgentPaneRememberedPick, by model: AgentPaneModel) {
        let picked = pick.agent + "/" + (pick.model ?? "") + (pick.dismissesHarnessHint ? "/hint-dismissed" : "")
            + (pick.started.map { "/started:" + $0 } ?? "")
            + (pick.cloudAgent.map { "/cloud:" + $0.harness + "/" + ($0.model ?? "") + "/" + ($0.effort ?? "") } ?? "")
        pages[ObjectIdentifier(model), default: Page(model: model)].picked = picked
        update(\.model, picked)
    }

    private func update<Value: Equatable>(_ field: WritableKeyPath<Content, Value>, _ value: Value) {
        guard content[keyPath: field] != value else { return }
        content[keyPath: field] = value
        generation &+= 1
        frames = []
    }
}

extension AgentPageRedraw {
    /// From the pane view's ``AgentPaneView/layout()``: a New Tab page that has not painted asks its pane for its
    /// picture (``AgentPaneView/drawsLastPage``) at each size it gets in a pane. A pane can show its page before the
    /// pane's own first layout (a new workspace's pane made with its page's view: a spare still loading), when it has
    /// no size to pick a frame by (``AgentPaneNewTabFrame/image(size:appearance:)``). A view laid out in its pane is
    /// in the pane's layout pass, so the frame at the pane's size is in the pane's first frame with this view. A view
    /// still parked (``PageOffscreenParking``: a spare its pane has not taken yet) asks nothing: its pane has no size
    /// yet and gives no picture; the move into the pane asks again (``paneWired(_:)``). A pane that already shows
    /// a picture keeps it (the closure draws none over one).
    func askPictureAtNewSize(of pane: NSView) {
        guard let view = pane as? AgentPaneView, view.model.newTab != nil, !view.model.hasPainted, view.bounds.size != pictureAskedAt,
              !view.bounds.isEmpty, !(view.superview is PageOffscreenParking), let draw = view.drawsLastPage else { return }
        pictureAskedAt = view.bounds.size
        _ = draw()
    }

    /// A pane set `view`'s ``AgentPaneView/drawsLastPage`` (each show), or `view` has another superview (a parked
    /// spare its pane took): the page asks that pane again at its next layout, also at a size it asked its last pane
    /// at (a spare closed before it painted, taken again by the next Cmd-N) or at the size it was parked at.
    func paneWired(_ view: AgentPaneView) {
        pictureAskedAt = .zero
        if view.model.newTab != nil, !view.model.hasPainted { view.needsLayout = true }
    }
}
