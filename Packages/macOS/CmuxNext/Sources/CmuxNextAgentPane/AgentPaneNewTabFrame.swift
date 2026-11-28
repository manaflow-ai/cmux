public import AppKit
import CmuxNextWakeups

/// The app's last New Tab page frame (cx-ec99): a New Tab page that has not painted draws it, so
/// Cmd-T never shows an empty pane. It is kept with what it shows: a change of the chat list or of
/// the picked model drops it (and every page's own remembered frame, `AgentPageRedraw`), so no page
/// ever draws old chats or an old model; its size and appearance must match the pane's.
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
    private var frame: (image: NSImage, size: CGSize, appearance: NSAppearance.Name?, generation: UInt64)?

    public init() {}

    /// The frame drawn at `size` (zero: a pane not laid out yet) and `appearance`, with today's content.
    public func image(size: CGSize, appearance: NSAppearance.Name?) -> NSImage? {
        guard let frame, frame.generation == generation, frame.appearance == appearance,
              size == .zero || size == frame.size else { return nil }
        return frame.image
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
                guard let self, let view, let host, let redraw, view.model.newTab != nil, view.isDescendant(of: host),
                      view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
                let size = host.bounds.size, appearance = host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                let takenAt = self.generation, before = self.shows(view.model)
                guard size != .zero, before.0, self.image(size: size, appearance: appearance) == nil else { return }
                // One page frame first: an answer handed to the page before this is drawn by then.
                await withCheckedContinuation { done in redraw.afterNextFrame { done.resume() } }
                guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.isDescendant(of: host), host.bounds.size == size,
                      let snapshot = try? await view.webView.takeSnapshot(configuration: nil), snapshot.size == size,
                      takenAt == self.generation, self.shows(view.model) == before else { return }
                self.frame = (snapshot, size, appearance, takenAt)
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
        pages[ObjectIdentifier(model), default: Page(model: model)].picked = picked
        update(\.model, picked)
    }

    private func update<Value: Equatable>(_ field: WritableKeyPath<Content, Value>, _ value: Value) {
        guard content[keyPath: field] != value else { return }
        content[keyPath: field] = value
        generation &+= 1
        frame = nil
    }
}
