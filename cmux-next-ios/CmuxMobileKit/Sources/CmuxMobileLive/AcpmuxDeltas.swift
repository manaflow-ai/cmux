import CmuxMobileAgentChat
import Foundation

/// The phone's side of two compact forms the Mac's acpmux sends a client that asks for them in
/// `initialize` `_meta.acpmux` (``AcpmuxDeltas/initializeMeta``). An older Mac ignores both keys
/// and sends every record and row whole, as before; this reads both forms.
///
/// - `chunkDeltas` (cmux-tui acpmux `server/chunk_deltas.rs`): a streamed text chunk after the
///   first goes as `_acpmux/chunk {ref, seq, dt, text}` (at most about 100 B) in place of the whole
///   `_acpmux/event` (about 435 B). The full event before it carries `chunkRef`; the chunk is that
///   event with this `seq`, `at` the previous frame's plus `dt`, and
///   `msg.params.update.content.text` this text.
/// - `sessionChangedDelta` (`server/session_patch.rs`, `session-changed-delta-v1`): each
///   `_acpmux/session_changed` carries `rowSeq`, and after it a chat's row change comes as
///   `_acpmux/session_patch {patch, rowSeq, baseRowSeq, ...}`: a JSON merge patch (RFC 7386,
///   `null` removes a key) of the row held at `baseRowSeq`, where `{"$splice": [from, keep,
///   items]}` stands for an array that is `held[from..from + keep]` then `items`. A chat's row is
///   up to 77 KB on a 10,000-message chat, and it went out whole on every record of a turn.
///
/// What comes out is what the whole forms gave: the same `_acpmux/event` params (without
/// `chunkRef`) and the same `session_changed` params (with the row). A chunk whose `ref` this
/// connection never heard, or a patch whose base is not the row held, comes out as a resync
/// (``Chunk/unknownRef``, ``Row/gap``), never as a guess. One value per connection.
struct AcpmuxDeltas {
    /// What `initialize` adds to `_meta.acpmux`.
    static let initializeMeta: [String: JSONValue] = [
        "chunkDeltas": .bool(true),
        "sessionChangedDelta": .bool(true),
    ]

    /// The last full chunk event of one chat, as the next compact chunk applies to it.
    private struct Template {
        var sessionID: String
        /// The event's params, `chunkRef` taken out.
        var params: JSONValue
        var seq: Double
        var at: Double
    }

    private var templates: [Int: Template] = [:]
    /// Each chat's live `ref` (the Mac keeps one per chat).
    private var refs: [String: Int] = [:]
    /// Each chat's row at its `rowSeq`, as the Mac last sent it to this connection.
    private var rows: [String: (rowSeq: Double, row: JSONValue)] = [:]

    // MARK: Chunks

    /// An `_acpmux/event`'s params as the chat applies them: a `chunkRef` starts that chat's
    /// template (and is taken out); anything else passes as it came.
    mutating func event(_ params: JSONValue) -> JSONValue {
        guard case .object(var object) = params, let ref = object["chunkRef"]?.numberValue else { return params }
        object["chunkRef"] = nil
        let event = JSONValue.object(object)
        if let sessionID = object["sessionId"]?.stringValue {
            if let old = refs[sessionID] { templates[old] = nil }
            refs[sessionID] = Int(ref)
            templates[Int(ref)] = Template(sessionID: sessionID, params: event,
                                           seq: object["seq"]?.numberValue ?? 0, at: object["at"]?.numberValue ?? 0)
        }
        return event
    }

    enum Chunk: Equatable {
        /// The chat's `_acpmux/event` params, as the whole form carried them.
        case event(sessionID: String, params: JSONValue)
        /// A `ref` this connection holds no template for: its event cannot be rebuilt.
        case unknownRef
    }

    /// An `_acpmux/chunk`'s params, rebuilt into the event it stands for.
    mutating func chunk(_ params: JSONValue) -> Chunk {
        guard let ref = params["ref"]?.numberValue, var template = templates[Int(ref)],
              let seq = params["seq"]?.numberValue, let text = params["text"]?.stringValue,
              case .object(var object) = template.params else { return .unknownRef }
        let at = template.at + (params["dt"]?.numberValue ?? 0)
        object["seq"] = .number(seq)
        object["at"] = .number(at)
        guard let rebuilt = Self.setting(.object(object), ["msg", "params", "update", "content", "text"], to: .string(text)) else {
            return .unknownRef
        }
        template.seq = seq
        template.at = at
        templates[Int(ref)] = template
        return .event(sessionID: template.sessionID, params: rebuilt)
    }

    // MARK: Rows

    enum Row: Equatable {
        /// `session_changed` params with the chat's whole row in `session`.
        case changed(JSONValue)
        /// A patch whose base is not the row held: what this connection holds is out of date.
        case gap(sessionID: String)
    }

    /// The key a chat's row is held under: a peer's chat by the id its row has here.
    private static func key(_ params: JSONValue) -> String? {
        params["qualifiedSessionId"]?.stringValue ?? params["sessionId"]?.stringValue ?? params["session"]?["sessionId"]?.stringValue
    }

    /// A `session_changed`'s params: a row with `rowSeq` is held for the patches after it.
    mutating func changed(_ params: JSONValue) -> JSONValue {
        guard let key = Self.key(params) else { return params }
        if params["kind"]?.stringValue == "purged" {
            rows[key] = nil
        } else if let rowSeq = params["rowSeq"]?.numberValue, let row = params["session"] {
            rows[key] = (rowSeq, row)
        }
        return params
    }

    /// A `session_patch`'s params, applied to the row held, as the `session_changed` the whole
    /// form carried: the same params with `session` the new row and no `patch` or `baseRowSeq`.
    mutating func patch(_ params: JSONValue) -> Row {
        guard let key = Self.key(params) else { return .gap(sessionID: "") }
        guard let held = rows[key], let base = params["baseRowSeq"]?.numberValue, base == held.rowSeq,
              let rowSeq = params["rowSeq"]?.numberValue, let patch = params["patch"],
              let row = Self.apply(patch, to: held.row), case .object(var object) = params else {
            rows[key] = nil
            return .gap(sessionID: key)
        }
        rows[key] = (rowSeq, row)
        object["patch"] = nil
        object["baseRowSeq"] = nil
        object["session"] = row
        return .changed(.object(object))
    }

    /// The row held for a chat (tests).
    func heldRow(_ key: String) -> JSONValue? { rows[key]?.row }

    /// `patch` applied to `target` (`server/session_patch.rs`'s form); nil for a `$splice` that
    /// does not fit the array held.
    static func apply(_ patch: JSONValue, to target: JSONValue?) -> JSONValue? {
        guard case .object(let fields) = patch else { return patch }
        if fields.count == 1, let splice = fields["$splice"]?.arrayValue {
            guard splice.count == 3, let from = splice[0].numberValue.map(Int.init), let keep = splice[1].numberValue.map(Int.init),
                  let items = splice[2].arrayValue, from >= 0, keep >= 0 else { return nil }
            let held = target?.arrayValue ?? []
            guard from + keep <= held.count else { return nil }
            return .array(Array(held[from..<(from + keep)]) + items)
        }
        var object: [String: JSONValue]
        if case .object(let held)? = target { object = held } else { object = [:] }
        for (key, value) in fields {
            if value == .null {
                object[key] = nil
            } else {
                guard let next = apply(value, to: object[key]) else { return nil }
                object[key] = next
            }
        }
        return .object(object)
    }

    /// `value` with `path` set to `leaf`; nil when a step on the way is not an object.
    private static func setting(_ value: JSONValue, _ path: ArraySlice<String>, to leaf: JSONValue) -> JSONValue? {
        guard let first = path.first else { return leaf }
        guard case .object(var object) = value, let inner = object[first],
              let next = setting(inner, path.dropFirst(), to: leaf) else { return nil }
        object[first] = next
        return .object(object)
    }

    private static func setting(_ value: JSONValue, _ path: [String], to leaf: JSONValue) -> JSONValue? {
        setting(value, path[...], to: leaf)
    }
}
