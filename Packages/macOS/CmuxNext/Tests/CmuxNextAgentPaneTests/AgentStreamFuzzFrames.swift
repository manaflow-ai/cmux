import CmuxFuzzSupport
import Foundation
@testable import CmuxNextAgentPane

/// What the relay does with one daemon frame (``AcpmuxRequestIds/toPage(_:)``), as its contract says.
nonisolated enum AgentStreamExpect: Equatable {
    /// A notification: to the page as a fresh serialization of itself.
    case page
    /// A reply to a request the relay has open: to the page under the page's raw id.
    case reply(raw: String)
    /// acpmux's answer to a reply in place (``AgentPaneAgentReply``): the host finishes it.
    case complete(raw: String)
    /// Not one JSON object, or a reply to no open request: dropped and counted.
    case drop
    /// One object holds two equal keys: the socket closes.
    case close
}

/// One step of a daemon stream.
nonisolated enum AgentStreamStep {
    /// The page sent request `raw` for `method`; `relayID` is the relay id it gets, nil while `raw` is in flight.
    case begin(raw: String, method: String, subject: String?, relayID: Int?)
    /// The request with relay id `relayID` was not sent after all.
    case cancel(relayID: Int)
    /// One daemon frame, what the relay does with it, and the value it was written from (nil for text that is none).
    case frame(String, AgentStreamExpect, FuzzJSON?)
}

/// The daemon frames of the stream suite, built from the fields the relay and its observers read
/// (``AcpmuxRequestIds``, ``AcpmuxPaneSessions``, ``AcpmuxPermissionOptions``, ``AcpmuxDecisionContexts``,
/// ``AcpmuxPaneSocket/pageWaits(on:)``): each field missing, of a wrong type or one of a few values, as
/// Chromium's structure-aware fuzzing guide builds inputs (testing/libfuzzer/structure_aware_fuzzing.md).
nonisolated enum AgentStreamFrames {
    static let sessions = ["s1", "s2", "s3", "é", "s\u{0}"]
    static let permissions = ["p1", "p2", "p3"]
    static let optionIDs = ["yes", "no", "always"]
    static let optionKinds = ["allow_once", "allow_always", "reject_once", "reject_always", "rejected", "", "allow"]
    /// acpmux's forms (64 and 32 lowercase hex digits) and near misses the pane drops.
    static let nonces = [String(repeating: "ab", count: 32), String(repeating: "0f", count: 32),
                         String(repeating: "AB", count: 32), String(repeating: "ab", count: 31)]
    static let instances = [String(repeating: "c", count: 32), String(repeating: "19", count: 16),
                            String(repeating: "C", count: 32), "c"]
    static let folders = ["/tmp/a", "/", "relative", "", "/é/\u{0}"]
    static let eventKinds = ["permission_request", "permission_reissued", "turn_end", "turn_result", "turn_start", "agent_message_chunk"]
    static let dirs = ["mux", "agent", "client", "MUX"]
    static let promptIDs = ["pr-1", "pr-2", "", "é"]
    /// The requests a page sends whose replies the observers read, and two whose replies they do not.
    static let methods = ["session/new", "acp.session.fork", "_acpmux/attach", "_acpmux/events", "_acpmux/watch",
                          "_acpmux/status", AcpmuxPaneMethods.initialize, "session/prompt", AgentPaneAgentReply.method]

    /// JSON pieces the byte mutator splices in: the format's tokens and the stream's own keys and methods.
    static let tokens: [Data] = FuzzJSON.tokens + [
        "\"method\"", "\"id\"", "\"result\"", "\"params\"", "\"error\"", "\"_acpmux/event\"", "\"_acpmux/permission_pending\"",
        "\"sessionId\"", "\"events\"", "\"\\u00e9\"", "\"e\\u0301\"", "\"mux\"", "\"permission_request\"",
    ].map { Data($0.utf8) }

    // MARK: Fields

    /// A string field: missing one time in eight, of another type one in eight, else one of `values`.
    static func field(_ values: [String], _ rng: inout FuzzRNG) -> FuzzJSON? {
        switch rng.below(8) {
        case 0: return nil
        case 1: return FuzzJSON.random(&rng, notOf: [.string])
        default: return .string(rng.element(of: values) ?? "")
        }
    }

    /// A field of type `kind`: missing one time in eight, of another type one in eight, else `make`'s.
    static func maybe(_ kind: FuzzJSON.Kind, _ rng: inout FuzzRNG, _ make: (inout FuzzRNG) -> FuzzJSON) -> FuzzJSON? {
        switch rng.below(8) {
        case 0: return nil
        case 1: return FuzzJSON.random(&rng, notOf: [kind])
        default: return make(&rng)
        }
    }

    /// A record's `seq`: a small count, missing, or a value that is no number (never a boolean, which
    /// Foundation reads as the number 0 or 1).
    static func seq(_ rng: inout FuzzRNG) -> FuzzJSON? {
        switch rng.below(8) {
        case 0: return nil
        case 1: return FuzzJSON.random(&rng, notOf: [.number, .bool])
        default: return .int(Int64(rng.below(64)))
        }
    }

    /// An object of `fields` (missing ones left out) and up to two fields no code reads.
    static func object(_ fields: [String: FuzzJSON?], _ rng: inout FuzzRNG) -> FuzzJSON {
        var members: [String: FuzzJSON] = [:]
        for (key, value) in fields {
            if let value { members[key] = value }
        }
        for _ in 0..<rng.below(3) {
            let key = "x" + rng.text(["a", "b", "1"], 5)
            members[key] = FuzzJSON.random(&rng)
        }
        return .object(members)
    }

    // MARK: Records

    /// A permission request's `request`: its `options`, each an `{optionId, kind}` or a value of another type.
    static func request(_ rng: inout FuzzRNG) -> FuzzJSON? {
        maybe(.object, &rng) { r in
            let options = maybe(.array, &r) { r in
                .array((0..<r.below(4)).map { _ -> FuzzJSON in
                    if r.oneIn(6) { return FuzzJSON.random(&r, notOf: [.object]) }
                    let option: [String: FuzzJSON?] = ["optionId": field(optionIDs, &r), "kind": field(optionKinds, &r)]
                    return object(option, &r)
                })
            }
            let fields: [String: FuzzJSON?] = ["options": options]
            return object(fields, &r)
        }
    }

    /// The prompt of a `_acpmux/permission_pending` (`session`: its params carry the session) or of a record's `msg`.
    static func prompt(_ rng: inout FuzzRNG, session: Bool) -> FuzzJSON {
        let fields: [String: FuzzJSON?] = [
            "sessionId": session ? field(sessions, &rng) : nil,
            "permissionId": field(permissions, &rng),
            "decisionNonce": field(nonces, &rng),
            "personInstance": field(instances, &rng),
            "seq": seq(&rng),
            "request": request(&rng),
        ]
        return object(fields, &rng)
    }

    /// One record of acpmux's event log, as `_acpmux/event` sends it and history replies list it.
    static func record(_ rng: inout FuzzRNG) -> FuzzJSON {
        let msg = maybe(.object, &rng) { r in prompt(&r, session: false) }
        let fields: [String: FuzzJSON?] = [
            "dir": field(dirs, &rng), "kind": field(eventKinds, &rng), "sessionId": field(sessions, &rng),
            "seq": seq(&rng), "msg": msg,
        ]
        return object(fields, &rng)
    }

    /// A history reply's `events`: records and values of other types.
    static func events(_ rng: inout FuzzRNG) -> FuzzJSON? {
        maybe(.array, &rng) { r in
            .array((0..<r.below(4)).map { _ -> FuzzJSON in r.oneIn(6) ? FuzzJSON.random(&r, notOf: [.object]) : record(&r) })
        }
    }

    // MARK: Frames

    /// A notification, marked `mark` at its top level (the page gets every member of a notification).
    static func notification(_ rng: inout FuzzRNG, mark: Int) -> FuzzJSON {
        let method: FuzzJSON
        let params: FuzzJSON?
        switch rng.below(7) {
        case 0:
            method = .string("_acpmux/permission_pending")
            params = maybe(.object, &rng) { r in prompt(&r, session: true) }
        case 1:
            method = .string("_acpmux/event")
            params = maybe(.object, &rng) { r in record(&r) }
        case 2:
            method = .string("_acpmux/prompt_accepted")
            params = maybe(.object, &rng) { r in
                let fields: [String: FuzzJSON?] = ["promptId": field(promptIDs, &r)]
                return object(fields, &r)
            }
        case 3:
            method = .string("session/update")
            // A huge text one time in thirty-two: 16 KiB to 1 MiB on one line.
            let text = rng.oneIn(32) ? FuzzText.hugeLine(bytes: 1 << rng.int(in: 14...20), &rng) : FuzzJSON.randomString(&rng)
            let update = FuzzJSON.random(&rng, depth: 3)
            let fields: [String: FuzzJSON?] = ["sessionId": field(sessions, &rng), "text": .string(text), "update": update]
            params = object(fields, &rng)
        case 4:
            method = FuzzJSON.random(&rng, notOf: [.string])
            params = FuzzJSON.random(&rng)
        default:
            method = .string(rng.oneIn(2) ? FuzzJSON.randomString(&rng) : "_acpmux/status_changed")
            params = rng.oneIn(4) ? nil : FuzzJSON.random(&rng)
        }
        var fields: [String: FuzzJSON?] = ["jsonrpc": .string("2.0"), "method": method, "params": params, "mark": .int(Int64(mark))]
        // A notification that also carries an id is still one (the page waits on it).
        if rng.oneIn(16) { fields["id"] = FuzzJSON.random(&rng) }
        return object(fields, &rng)
    }

    /// acpmux's reply to `method` with relay id `id` (nil: none): a result in the shape the observers read, an
    /// error, or a result of another type.
    static func reply(id: FuzzJSON?, method: String, _ rng: inout FuzzRNG) -> FuzzJSON {
        var fields: [String: FuzzJSON?] = ["jsonrpc": .string("2.0"), "id": id]
        switch rng.below(8) {
        case 0:
            let error: [String: FuzzJSON?] = ["code": rng.oneIn(4) ? FuzzJSON.random(&rng) : FuzzJSON.int(-32603),
                                              "message": field(["failed", ""], &rng)]
            fields["error"] = object(error, &rng)
        case 1:
            fields["result"] = FuzzJSON.random(&rng, notOf: [.object])
        default:
            fields["result"] = result(for: method, &rng)
        }
        return object(fields, &rng)
    }

    /// A result for `method`, its fields right, missing or of a wrong type.
    static func result(for method: String, _ rng: inout FuzzRNG) -> FuzzJSON {
        var fields: [String: FuzzJSON?] = [:]
        switch method {
        case "session/new", "acp.session.fork":
            fields["sessionId"] = field(sessions, &rng)
            if rng.oneIn(4) { fields["targetSessionId"] = field(sessions, &rng) }
            fields["_meta"] = maybe(.object, &rng) { r in
                let acpmux = maybe(.object, &r) { r in
                    let meta: [String: FuzzJSON?] = ["cwd": field(folders, &r), "harness": field(["claude", "providers/deepseek", "bad name"], &r)]
                    return object(meta, &r)
                }
                let wrapper: [String: FuzzJSON?] = ["acpmux": acpmux]
                return object(wrapper, &r)
            }
        case "_acpmux/attach":
            fields["session"] = maybe(.object, &rng) { r in
                let session: [String: FuzzJSON?] = ["sessionId": field(sessions, &r), "cwd": field(folders, &r)]
                return object(session, &r)
            }
            fields["events"] = events(&rng)
        case "_acpmux/events":
            fields["events"] = events(&rng)
        case "_acpmux/watch":
            fields["tabSessionId"] = field(sessions + [""], &rng)
            fields["events"] = events(&rng)
        case AcpmuxPaneMethods.initialize:
            fields["protocolVersion"] = FuzzJSON.int(1)
            fields["_meta"] = maybe(.object, &rng) { r in
                let acpmux = maybe(.object, &r) { r in
                    let meta: [String: FuzzJSON?] = ["personInstance": field(instances, &r),
                                                     "personChallenge": FuzzJSON.random(&r)]
                    return object(meta, &r)
                }
                let wrapper: [String: FuzzJSON?] = ["acpmux": acpmux]
                return object(wrapper, &r)
            }
        case "_acpmux/status":
            fields["peers"] = maybe(.array, &rng) { r in .array((0..<r.below(3)).map { _ -> FuzzJSON in FuzzJSON.random(&r) }) }
        case AgentPaneAgentReply.method:
            fields["reply"] = maybe(.object, &rng) { r in
                let reply: [String: FuzzJSON?] = [
                    "from": field(["acp:s1", "acp:s2", "x"], &r), "replyTo": field(["m1"], &r), "threadId": field(["t1"], &r),
                    "text": field(["hi", ""], &r), "idempotencyKey": field(["k1"], &r),
                ]
                return object(reply, &r)
            }
        default:
            fields["value"] = FuzzJSON.random(&rng)
        }
        return object(fields, &rng)
    }

    /// A relay id the relay never maps: a decimal string, a fraction, a boolean, null, a negative number or
    /// a number past every 64-bit type (`id` is the open relay id it is near).
    static func unusableID(near id: Int, _ rng: inout FuzzRNG) -> FuzzJSON? {
        switch rng.below(7) {
        case 0: return .string(String(id))
        case 1: return .double(Double(id) + 0.5)
        case 2: return .bool(true)
        case 3: return .null
        case 4: return .int(-1 - Int64(rng.below(4)))
        case 5: return .uint(.max)
        default: return nil
        }
    }

    /// Text that is not one JSON object: empty, cut inside a frame, a value of another type, garbage
    /// behind a control byte, or arrays nested deep.
    static func notAnObject(_ frame: String, _ rng: inout FuzzRNG) -> String {
        switch rng.below(5) {
        case 0:
            return ""
        case 1:
            // A frame cut at a scalar strictly inside it: an object's text ends with its closing brace.
            let scalars = Array(frame.unicodeScalars)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars.prefix(rng.int(in: 1...max(1, scalars.count - 1))))
            return String(view)
        case 2:
            return rng.element(of: ["[]", "\"x\"", "42", "null", "true", "[{\"method\":\"x\"}]", "-0"]) ?? "[]"
        case 3:
            return "\u{1}" + String(decoding: rng.bytes(64), as: UTF8.self)
        default:
            let depth = rng.int(in: 1...64)
            return String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        }
    }

    /// A frame with two equal keys in one object: the same key twice, or the composed and the decomposed
    /// accent (equal as Swift strings), at the top or nested.
    static func duplicateKeys(_ rng: inout FuzzRNG) -> String {
        rng.element(of: [
            #"{"jsonrpc":"2.0","method":"a","method":"b"}"#,
            #"{"jsonrpc":"2.0","id":1,"id":2,"result":{}}"#,
            #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"\u00e9":1,"e\u0301":2}}"#,
            #"{"jsonrpc":"2.0","method":"x","params":{"a":[{"k":1,"k":1}]}}"#,
        ]) ?? "{}"
    }
}

nonisolated extension FuzzJSON {
    /// The value at `key` of an object; nil for a missing key or any other value.
    subscript(key: String) -> FuzzJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var arrayItems: [FuzzJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// A `seq` as Foundation's `NSNumber.uint64Value` reads it: only the generator's non-negative counts.
    var seqValue: UInt64? {
        if case .int(let value) = self, value >= 0 { return UInt64(value) }
        return nil
    }
}
