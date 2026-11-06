import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The group editor page's ops (`cmux.groupEditor.*`, webviews/src/pages/group-editor/host.ts): the
/// session stream and the person's edits. One provider lives as long as the warm page
/// (``GroupEditorService``); every call names its session, and a call for any other session is dropped,
/// so a late click never edits the group a newer open shows.
@MainActor
final class GroupEditorProvider: PageProvider {
    static let sessionStream = "cmux.groupEditor.session"

    /// One thing the person did, for the open session.
    enum Call: Equatable {
        /// The page painted `revision`; its card is `height` points tall.
        case ready(revision: Int, height: Double)
        case draft(String)
        case color(String)
        case customColor
        case item(String)
        case close
    }

    /// The last event pushed (the page's first subscribe gets it); nil before the first open.
    private(set) var event: JSONValue?
    /// The open session's id; nil when no editor is open.
    var openSession: String?
    var onCall: ((Call) -> Void)?
    private var listener: (@MainActor (JSONValue) -> Void)?

    /// Shows `event` (a new open, or a refresh of the open one).
    func push(_ event: JSONValue) {
        self.event = event
        listener?(event)
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let call = Self.decode(op, params) else { throw PageError.invalidParams(op) }
        // A call from an earlier open (a late click after a close) edits nothing.
        guard let session = params["session"]?.stringValue, session == openSession else { return .null }
        onCall?(call)
        return .null
    }

    /// The call `op` names, or nil when `op` or its params are not the page's.
    static func decode(_ op: String, _ params: JSONValue) -> Call? {
        switch op {
        case "cmux.groupEditor.ready":
            guard let revision = params["revision"]?.intValue, let height = params["height"]?.doubleValue, height > 0 else { return nil }
            return .ready(revision: revision, height: height)
        case "cmux.groupEditor.draft": return params["name"]?.stringValue.map(Call.draft)
        case "cmux.groupEditor.color": return params["color"]?.stringValue.map(Call.color)
        case "cmux.groupEditor.customColor": return .customColor
        case "cmux.groupEditor.item": return params["item"]?.stringValue.map(Call.item)
        case "cmux.groupEditor.close": return .close
        default: return nil
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.sessionStream else { throw PageError.unknownOp(stream) }
        listener = onEvent
        // The page subscribes once per load (a reload after a crash too): the open session, else none.
        onEvent(event ?? .object(["id": .string(""), "revision": .number(0)]))
        return PageSubscription { [weak self] in self?.listener = nil }
    }
}
