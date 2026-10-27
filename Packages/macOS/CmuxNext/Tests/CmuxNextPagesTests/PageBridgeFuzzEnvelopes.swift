import CmuxFuzzSupport
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Page envelopes (plans/cmux-next/pane-protocol.md "Wire"): each field the router reads right, missing, of a
/// wrong type, or a number no counter reaches (Infinity, NaN, 1e20, past 2^53), among the native ops, the
/// fuzz page's own ops and streams, and ops no route serves.
nonisolated enum PageBridgeEnvelopes {
    static let namespace = "cmux.fuzz."
    static let ops = [
        "cmux.fuzz.echo", "cmux.fuzz.fail", "cmux.fuzz.boom", "cmux.fuzz.", "cmux.other.op", "cmux.fuzz.\u{E9}",
        PageNativeOp.keepAlive, PageNativeOp.titleBarDoubleClick, PageNativeOp.popupShow, PageNativeOp.popupUpdate,
        PageNativeOp.popupHide, PageNativeOp.contextMenu,
    ]
    static let streams = [
        "cmux.fuzz.events", "cmux.fuzz.failstream", PageNativeOp.pageCommand, PageNativeOp.pageConnection, PageNativeOp.pagePopup,
        "cmux.fuzz.", "cmux.nope.stream",
    ]
    static let types = ["call", "call", "call", "sub", "sub", "cancel", "unsub", "ok", "err", "ev", "", "CALL"]
    static let opids = ["op-1", "", String(repeating: "a", count: 129), "a b", "\u{E9}", "a.b:c_d-1"]
    /// Params a page may not send: the host sets them.
    static let reserved = ["origin", "confirmed", "confirmation"]

    /// A number for an `id` or `sub`: a small count, or one at or past an edge.
    static func number(_ rng: inout FuzzRNG) -> JSONValue {
        switch rng.below(12) {
        case 0: return .number(Double.infinity)
        case 1: return .number(-Double.infinity)
        case 2: return .number(Double.nan)
        case 3: return .number(1e20)
        case 4: return .number(9_007_199_254_740_994)
        case 5: return .number(-3)
        case 6: return .number(1.5)
        case 7: return .string("4")
        default: return .number(Double(rng.below(40)))
        }
    }

    /// Any value, nested at most `depth` deep, sometimes a huge string.
    static func value(_ rng: inout FuzzRNG, depth: Int = 2) -> JSONValue {
        switch rng.below(depth > 0 ? 8 : 6) {
        case 0: return .null
        case 1: return .bool(rng.bool())
        case 2: return .number(rng.double(in: -1e6...1e6))
        case 3: return number(&rng)
        case 4: return .string(rng.oneIn(32) ? FuzzText.hugeLine(bytes: 1 << rng.int(in: 12...20), &rng) : FuzzJSON.randomString(&rng))
        case 5: return .string(rng.element(of: ["user_edits", "draft", "visible", "on"]) ?? "")
        case 6: return .array((0..<rng.below(4)).map { _ in value(&rng, depth: depth - 1) })
        default: return params(&rng, depth: depth - 1)
        }
    }

    /// Params or a filter: an object of a few keys (a reserved one sometimes), or a value of another type.
    static func params(_ rng: inout FuzzRNG, depth: Int = 1) -> JSONValue {
        if rng.oneIn(8) { return value(&rng, depth: 0) }
        var members: [String: JSONValue] = [:]
        for _ in 0..<rng.below(4) {
            let key = rng.oneIn(6) ? (rng.element(of: reserved) ?? "") : (rng.element(of: ["a", "reason", "on", "x"]) ?? "")
            members[key] = value(&rng, depth: max(depth - 1, 0))
        }
        return .object(members)
    }

    static func envelope(_ rng: inout FuzzRNG) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if !rng.oneIn(16) { fields["t"] = rng.oneIn(12) ? value(&rng, depth: 0) : .string(rng.element(of: types) ?? "call") }
        if !rng.oneIn(6) { fields["id"] = number(&rng) }
        if !rng.oneIn(10) { fields["op"] = rng.oneIn(12) ? value(&rng, depth: 0) : .string(rng.element(of: ops) ?? "") }
        if rng.oneIn(4) { fields["opid"] = rng.oneIn(3) ? value(&rng, depth: 0) : .string(rng.element(of: opids) ?? "") }
        if !rng.oneIn(5) { fields["params"] = params(&rng) }
        if !rng.oneIn(4) { fields["stream"] = rng.oneIn(10) ? value(&rng, depth: 0) : .string(rng.element(of: streams) ?? "") }
        if rng.oneIn(3) { fields["filter"] = params(&rng) }
        if rng.oneIn(3) { fields["sub"] = number(&rng) }
        if rng.oneIn(4) { fields["value"] = value(&rng) }
        return .object(fields)
    }
}

/// The router's contract (``PageRouter``'s doc comment and pane-protocol.md), kept beside a real router: the
/// reply each envelope gets, the envelopes counted as bad messages, and the calls and streams that reach the
/// provider (only ops the page admits, with object params and no reserved key).
nonisolated struct PageBridgeModel {
    nonisolated enum Reply: Equatable {
        /// No reply (`null`): a cancel, an unsubscribe, a reply to a host call.
        case none
        case ok(UInt64, JSONValue)
        case err(UInt64, String)
        /// `cmux.page.keepAlive`: `{}`, or `invalid_params` for a reason the page may not set.
        case keepAlive(UInt64)
    }

    static let invalidParams = "cmux.protocol.invalid_params"
    static let unknownOp = "cmux.protocol.unknown_op"
    static let badMessage = "cmux.protocol.bad_message"

    private(set) var bad = 0
    private(set) var calls: [String] = []
    private(set) var streams: [String] = []
    private var nextSub: UInt64 = 1

    /// Whether a number is a counter: finite and at most 2^53 (JavaScript's largest exact integer).
    static func isCounter(_ number: Double) -> Bool { number.isFinite && number <= 9_007_199_254_740_992 }

    static func admits(_ op: String) -> Bool {
        op.hasPrefix(PageBridgeEnvelopes.namespace) && op.count > PageBridgeEnvelopes.namespace.count
    }

    private mutating func refuse(_ reply: Reply) -> Reply {
        bad += 1
        return reply
    }

    mutating func reply(to envelope: JSONValue) -> Reply {
        guard let type = envelope["t"]?.stringValue else { return refuse(.err(0, Self.invalidParams)) }
        var id: UInt64 = 0
        if let number = envelope["id"]?.doubleValue {
            guard Self.isCounter(number) else { return refuse(.err(0, Self.badMessage)) }
            id = UInt64(max(0, number))
        }
        switch type {
        case "call":
            return call(envelope, id: id)
        case "sub":
            return subscribe(envelope, id: id)
        case "unsub":
            if let number = envelope["sub"]?.doubleValue, !Self.isCounter(number) { bad += 1 }
            return .none
        case "cancel", "ok", "err":
            return .none
        default:
            return refuse(.err(id, Self.invalidParams))
        }
    }

    private mutating func call(_ envelope: JSONValue, id: UInt64) -> Reply {
        guard let op = envelope["op"]?.stringValue else { return refuse(.err(id, Self.invalidParams)) }
        if let opid = envelope["opid"] {
            // 1-128 characters of [A-Za-z0-9._:-] (decision 31, zero-latency.md).
            guard let text = opid.stringValue, (1...128).contains(text.count),
                  text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".:_-".contains($0)) }) else {
                return refuse(.err(id, Self.badMessage))
            }
        }
        let params = envelope["params"] ?? .object([:])
        switch op {
        case PageNativeOp.keepAlive:
            return .keepAlive(id)
        case PageNativeOp.titleBarDoubleClick:
            return .ok(id, .object([:]))
        case PageNativeOp.popupShow, PageNativeOp.popupUpdate, PageNativeOp.popupHide:
            return params.objectValue == nil ? .err(id, Self.invalidParams) : .ok(id, ["shown": false])
        case PageNativeOp.contextMenu:
            return params.objectValue == nil ? .err(id, Self.invalidParams) : .ok(id, ["picked": .null])
        default:
            guard Self.admits(op) else { return .err(id, Self.unknownOp) }
            guard let members = params.objectValue, !PageBridgeEnvelopes.reserved.contains(where: { members[$0] != nil }) else {
                return .err(id, Self.invalidParams)
            }
            calls.append(op)
            switch op {
            case "cmux.fuzz.fail": return .err(id, "cmux.fuzz.refused")
            case "cmux.fuzz.boom": return .err(id, "cmux.page.failed")
            default: return .ok(id, ["op": .string(op)])
            }
        }
    }

    private mutating func subscribe(_ envelope: JSONValue, id: UInt64) -> Reply {
        guard let stream = envelope["stream"]?.stringValue else { return refuse(.err(id, Self.invalidParams)) }
        if [PageNativeOp.pageCommand, PageNativeOp.pageConnection, PageNativeOp.pagePopup].contains(stream) {
            defer { nextSub += 1 }
            return .ok(id, ["sub": .number(Double(nextSub))])
        }
        guard Self.admits(stream) else { return .err(id, Self.unknownOp) }
        guard let members = (envelope["filter"] ?? .object([:])).objectValue,
              !PageBridgeEnvelopes.reserved.contains(where: { members[$0] != nil }) else {
            return .err(id, Self.invalidParams)
        }
        defer { nextSub += 1 }
        streams.append(stream)
        return stream == "cmux.fuzz.failstream" ? .err(id, "cmux.fuzz.refused") : .ok(id, ["sub": .number(Double(nextSub))])
    }

    /// Whether `reply` is the reply the model names.
    static func matches(_ reply: JSONValue, _ expected: Reply) -> Bool {
        func envelope(_ type: String, _ id: UInt64) -> Bool {
            reply["t"]?.stringValue == type && reply["id"]?.doubleValue == Double(id)
        }
        switch expected {
        case .none:
            return reply == .null
        case .ok(let id, let value):
            return envelope("ok", id) && reply["value"] == value
        case .err(let id, let code):
            return envelope("err", id) && reply["code"]?.stringValue == code
        case .keepAlive(let id):
            return (envelope("ok", id) && reply["value"] == .object([:])) || (envelope("err", id) && reply["code"]?.stringValue == invalidParams)
        }
    }
}
