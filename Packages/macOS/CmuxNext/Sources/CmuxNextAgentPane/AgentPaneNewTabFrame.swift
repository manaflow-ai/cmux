public import AppKit

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

    /// Keeps `image`, taken when the content was at `takenAt`; dropped when it moved meanwhile.
    public func remember(_ image: NSImage, size: CGSize, appearance: NSAppearance.Name?, takenAt: UInt64) {
        guard takenAt == generation else { return }
        frame = (image, size, appearance, takenAt)
    }

    /// A New Tab page got the first page of its chat list.
    public func chatsChanged(_ chats: [AcpmuxChat]) { update(\.chats, chats.hashValue) }

    /// A New Tab page picked an agent or model.
    public func modelChanged(agent: String, model: String?) { update(\.model, agent + "/" + (model ?? "")) }

    private func update<Value: Equatable>(_ field: WritableKeyPath<Content, Value>, _ value: Value) {
        guard content[keyPath: field] != value else { return }
        content[keyPath: field] = value
        generation &+= 1
        frame = nil
    }
}
