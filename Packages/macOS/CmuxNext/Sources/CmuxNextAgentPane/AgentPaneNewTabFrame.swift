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

    /// `view` (a New Tab page in `host`) 400 ms after it painted (its chats and chips in), clear
    /// areas left clear: what the next New Tab page draws until it paints. Only when no frame with
    /// today's content, size and appearance is held; one capture per page at a time, never of a
    /// hidden page, and kept only when the content did not move while it ran (perf-tabs I6).
    public func capture(_ view: AgentPaneView, in host: NSView) {
        let redraw = view.redraw
        guard !redraw.givesNewTabFrame else { return }
        redraw.givesNewTabFrame = true
        view.model.whenPainted { [weak self, weak view, weak host, weak redraw] in
            let settle = DemandTimer(owner: "newTab.frame.settle")
            settle.schedule(after: .milliseconds(400)) { @MainActor in
                withExtendedLifetime(settle) {}
                defer { redraw?.givesNewTabFrame = false }
                guard let self, let view, let host, view.model.newTab != nil, view.isDescendant(of: host),
                      view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
                let size = host.bounds.size, appearance = host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                let takenAt = self.generation
                guard size != .zero, self.shows(redraw), self.image(size: size, appearance: appearance) == nil,
                      let snapshot = try? await view.webView.takeSnapshot(configuration: nil),
                      takenAt == self.generation, self.shows(redraw) else { return }
                self.frame = (snapshot, size, appearance, takenAt)
            }
        }
    }

    /// `redraw`'s page draws today's chat list: it drew the last answer it asked for, and that
    /// answer is the current list (a page that has not asked since a change shows an old one).
    private func shows(_ redraw: AgentPageRedraw?) -> Bool {
        guard let redraw, redraw.pendingChats == 0 else { return false }
        return content.chats == nil || redraw.drawnChats == content.chats
    }

    /// A page asks for its chat list (`chats.page`); ``chatsAnswered(_:firstPage:to:)`` follows.
    public func chatsRequested(by page: AgentPaneView?) { page?.redraw.pendingChats += 1 }

    /// The first page of the chat list (no cursor, no search) reached `page`. The page draws a chat's
    /// key, title, folder and time, and the row design: other fields (a streamed preview) move nothing.
    public func chatsAnswered(_ answer: AgentPaneChatsPage?, firstPage: Bool, to page: AgentPaneView?) {
        var drawn: Int?
        if firstPage, let answer {
            var hasher = Hasher()
            for chat in answer.chats { hasher.combine(chat.id); hasher.combine(chat.title); hasher.combine(chat.cwd); hasher.combine(chat.updatedAt) }
            hasher.combine(answer.design); hasher.combine(answer.ready); hasher.combine(answer.enabled)
            drawn = hasher.finalize()
            update(\.chats, drawn)
        }
        guard let page else { return }
        page.redraw.afterNextFrame { [weak self, weak page] in
            guard let self, let page else { return }
            page.redraw.pendingChats = max(0, page.redraw.pendingChats - 1)
            if let drawn { page.redraw.drawnChats = drawn }
            // A New Tab page on screen gives the frame of what it shows now.
            if let host = page.superview { capture(page, in: host) }
        }
    }

    /// A New Tab page picked an agent or model (or dismissed the harness hint).
    public func modelChanged(_ pick: AgentPaneRememberedPick) {
        update(\.model, pick.agent + "/" + (pick.model ?? "") + (pick.dismissesHarnessHint ? "/hint-dismissed" : ""))
    }

    private func update<Value: Equatable>(_ field: WritableKeyPath<Content, Value>, _ value: Value) {
        guard content[keyPath: field] != value else { return }
        content[keyPath: field] = value
        generation &+= 1
        frame = nil
    }
}
