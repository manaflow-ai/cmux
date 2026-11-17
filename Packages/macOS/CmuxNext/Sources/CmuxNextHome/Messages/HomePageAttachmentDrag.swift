public import CmuxHomeCore
public import CmuxNextPages
public import CmuxNextSettings
public import AppKit
import MessagesLabHome

/// A Messages page attachment dragged out of the transcript to Finder, the Desktop or another app,
/// as the native Home's transcript did (the user, 2026-10-21: "i need to be able to drag it out to
/// other apps too"). The page cancels its own drag at its start and calls
/// `attachment.drag {conversation, message, partIndex, attachment: {hash, name, mimeType, byteCount, …}}`;
/// while the button is still held, the host starts a native drag of a file promise
/// (``HomeAttachmentDrag``) from a fresh dragged event at the pointer, so the drag never waits on
/// the network: the drop asks for the bytes, and `fetch` gets them then. A copy everywhere.
@MainActor
public final class HomePageAttachmentDrag {
    /// The page's op, under ``HomeMessagesPageRoute/prefix``.
    public nonisolated static let op = "attachment.drag"
    /// The window the page is in; nil while it has none.
    private let window: @MainActor () -> NSWindow?
    /// Fetches the original of `ref` where it appears; nil when it cannot.
    private let fetch: @MainActor @Sendable (AttachmentRef, AttachmentLocation) async -> URL?
    /// The refusal of a call no gesture of the person made.
    private let personOnly: String
    /// Whether the left button is down (a drag the page reported after the release starts nothing).
    var mouseHeld: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Starts the native drag of `item` with `source`; false without a window. Tests record it.
    var begin: @MainActor (NSDraggingItem, HomeAttachmentDrag, NSWindow?) -> Bool = HomePageAttachmentDrag.startDrag
    /// The running drag's source and promise delegate (a promise holds its delegate weakly, and
    /// Finder may ask for the file after the drag session ended); replaced by the next drag.
    private(set) var current: HomeAttachmentDrag?

    public init(window: @escaping @MainActor () -> NSWindow?, personOnly: String,
                fetch: @escaping @MainActor @Sendable (AttachmentRef, AttachmentLocation) async -> URL?) {
        self.window = window
        self.fetch = fetch
        self.personOnly = personOnly
    }

    /// The page's `attachment.drag` call: `{started}`; a call that no gesture of the person made is
    /// refused, and one with no attachment or place in it is invalid.
    public func call(_ params: JSONValue, userGesture: Bool) throws -> JSONValue {
        guard userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: personOnly) }
        guard let (ref, location) = Self.parse(params) else {
            throw PageError.invalidParams("attachment.drag needs conversation, message, partIndex and attachment {hash, name, mimeType, byteCount}")
        }
        guard mouseHeld() else { return .object(["started": .bool(false)]) }
        let fetch = self.fetch
        let drag = HomeAttachmentDrag(name: ref.name) { await fetch(ref, location) }
        let item = NSDraggingItem(pasteboardWriter: drag.writer(file: nil))
        let image = drag.preview(file: nil, size: CGSize(width: 64, height: 64))
        let window = window()
        let point = window.map { $0.contentView?.convert($0.mouseLocationOutsideOfEventStream, from: nil) ?? .zero } ?? .zero
        item.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        let started = begin(item, drag, window)
        if started { current = drag }
        return .object(["started": .bool(started)])
    }

    /// ``call(_:userGesture:)`` when `name` is ``op``; nil for the page's other ops.
    public func call(_ name: String, _ fields: [String: JSONValue], userGesture: Bool) throws -> JSONValue? {
        guard name == Self.op else { return nil }
        return try call(.object(fields), userGesture: userGesture)
    }

    /// The attachment and its place from the page's params; nil when one is missing or malformed.
    static func parse(_ params: JSONValue) -> (AttachmentRef, AttachmentLocation)? {
        guard let conversation = params["conversation"]?.stringValue, !conversation.isEmpty,
              let message = params["message"]?.stringValue, !message.isEmpty,
              let index = params["partIndex"]?.intValue, index >= 0,
              let part = params["attachment"], let hash = part["hash"]?.stringValue, !hash.isEmpty,
              let name = part["name"]?.stringValue else { return nil }
        let int = { (key: String) in part[key]?.intValue }
        let ref = AttachmentRef(hash: hash, name: name, mimeType: part["mimeType"]?.stringValue ?? "application/octet-stream",
                                byteCount: int("byteCount") ?? 0, width: int("width"), height: int("height"),
                                durationMs: int("durationMs"))
        return (ref, AttachmentLocation(conversation: ConversationID(conversation), message: MessageID(message), partIndex: index))
    }

    /// Starts the drag from the window's content view at the pointer (the page cancelled its own).
    private static func startDrag(_ item: NSDraggingItem, source: HomeAttachmentDrag, window: NSWindow?) -> Bool {
        guard let window, let view = window.contentView,
              let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
        view.beginDraggingSession(with: [item], event: event, source: source)
        return true
    }
}
