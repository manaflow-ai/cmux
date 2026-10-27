import CmuxFuzzSupport
import CmuxNextSettings
import Foundation
@testable import CmuxNextPages

/// The DevTools text a Chromium page's bridge reads (``ChromiumPageHostWire``): `Runtime.bindingCalled` events,
/// the binding's `{name, seq, body}` payload, the sender's `Runtime.evaluate` result and the document events,
/// each field right, missing or of a wrong type, and byte mutations of them.
nonisolated enum PageBridgeWire {
    /// Tokens the mutator splices in: JSON's and the wire's own names.
    static let tokens: [Data] = FuzzJSON.tokens + [
        "\"Runtime.bindingCalled\"", "\"Page.frameNavigated\"", "\"Page.loadEventFired\"", "\"params\"", "\"payload\"",
        "\"executionContextId\"", "\"name\"", "\"seq\"", "\"body\"", "\"frame\"", "\"parentId\"", "\"\\u00e9\"", "\"e\\u0301\"",
    ].map { Data($0.utf8) }

    /// Payloads with two keys that are equal Swift strings, at the top and nested: before the wire read objects
    /// through `JSONValue`, the `[String: Any]` cast of each trapped.
    static let equalKeys = [
        #"{"name":"cmuxPage","seq":1,"body":{"\u00e9":1,"e\u0301":2}}"#,
        #"{"name":"cmuxPage","\u00e9":0,"e\u0301":0,"body":null}"#,
        #"{"method":"Runtime.bindingCalled","params":{"name":"b","payload":"{}","executionContextId":1,"\u00e9":1,"e\u0301":2}}"#,
    ]

    /// A string field: the value three times in four, else missing or of a type that is no string.
    static func string(_ value: String, _ rng: inout FuzzRNG) -> (FuzzJSON?, ok: Bool) {
        switch rng.below(8) {
        case 0: return (nil, false)
        case 1: return (FuzzJSON.random(&rng, notOf: [.string]), false)
        default: return (.string(value), true)
        }
    }

    static func object(_ fields: [String: FuzzJSON?]) -> FuzzJSON {
        .object(fields.compactMapValues { $0 })
    }

    /// A binding call event whose parts are right or wrong; it reads as one exactly when all are right.
    static func bindingCall(_ rng: inout FuzzRNG) throws {
        let method = string("Runtime.bindingCalled", &rng)
        let name = string(rng.element(of: ["cmuxPage", "cmuxInputReady", "\u{E9}"]) ?? "", &rng)
        let payload = string(FuzzJSON.randomString(&rng), &rng)
        let context: (FuzzJSON?, ok: Bool) = rng.oneIn(6) ? (FuzzJSON.random(&rng, notOf: [.number, .bool]), false)
            : (.int(Int64(rng.int(in: -5...1_000))), true)
        let params: FuzzJSON? = rng.oneIn(10) ? FuzzJSON.random(&rng, notOf: [.object])
            : object(["name": name.0, "payload": payload.0, "executionContextId": context.0])
        let text = try object(["method": method.0, "params": params]).text()
        let call = ChromiumPageHostWire.BindingCall(event: text)
        let whole = method.ok && name.ok && payload.ok && context.ok && params?.kind == .object
        try FuzzRun.check((call != nil) == whole, "\(text.prefix(300)) read as \(String(describing: call))")
        if let call {
            try FuzzRun.check(.string(call.name) == name.0 && .string(call.payload) == payload.0 && .int(Int64(call.contextID)) == context.0,
                              "\(text.prefix(300)) read as \(call)")
        }
    }

    /// A payload whose parts are right or wrong: a message exactly when `name` is a string and `body` is there
    /// and `seq`, when a number, is above 0.
    static func message(_ rng: inout FuzzRNG) throws {
        let name = string("cmuxPage", &rng)
        let seq: FuzzJSON? = switch rng.below(4) {
        case 0: nil
        case 1: FuzzJSON.random(&rng, notOf: [.number, .bool])
        default: .int(Int64(rng.int(in: -2...9)))
        }
        let body: FuzzJSON? = rng.oneIn(8) ? nil : FuzzJSON.random(&rng, of: [.null, .bool, .string, .array, .object], depth: 2)
        let text = try object(["name": name.0, "seq": seq, "body": body]).text()
        let message = ChromiumPageHostWire.Message(payload: text)
        var whole = name.ok && body != nil
        if case .int(let value)? = seq, value <= 0 { whole = false }
        try FuzzRun.check((message != nil) == whole, "\(text.prefix(300)) read as \(String(describing: message))")
        guard let message, let body else { return }
        if case .int(let value)? = seq {
            try FuzzRun.check(message.seq == Int(value), "\(text.prefix(300)) read seq \(String(describing: message.seq))")
        } else {
            try FuzzRun.check(message.seq == nil, "\(text.prefix(300)) read seq \(String(describing: message.seq))")
        }
        try FuzzRun.check(JSONValue(foundation: message.body)?.compactText == JSONValue.parse(body.data()).compactText,
                          "\(text.prefix(300)) read body \(message.body)")
    }

    /// The sender evaluation: a sender exactly when there is no exception and the value is a string and a boolean.
    static func sender(_ rng: inout FuzzRNG) throws {
        let href = string(rng.element(of: ["cmux://settings/", "https://example.com/a b", ""]) ?? "", &rng)
        let top: (FuzzJSON?, ok: Bool) = rng.oneIn(6) ? (FuzzJSON.random(&rng, notOf: [.bool, .number]), false) : (.bool(rng.bool()), true)
        var items = [href.0 ?? .null, top.0 ?? .null]
        let count = rng.oneIn(8) ? rng.below(4) : 2
        while items.count > count { items.removeLast() }
        while items.count < count { items.append(.null) }
        let exception = rng.oneIn(8)
        let result = object(["value": .array(items)])
        let text = try object(["result": result, "exceptionDetails": exception ? .object([:]) : nil]).text()
        let sender = ChromiumPageHostWire.Sender(evaluation: text)
        let whole = !exception && count == 2 && href.ok && top.ok
        try FuzzRun.check((sender != nil) == whole, "\(text.prefix(300)) read as \(String(describing: sender))")
        if let sender, case .string(let value)? = href.0, case .bool(let isTop)? = top.0 {
            try FuzzRun.check(sender == ChromiumPageHostWire.Sender(url: URL(string: value), isTop: isTop), "\(text.prefix(300)) read as \(sender)")
        }
    }

    /// A document event: finished for a load, committed at the URL and fragment for a main frame's navigation,
    /// nothing for a reply, a child frame or a wrong shape.
    static func documentEvent(_ rng: inout FuzzRNG) throws {
        let load = rng.bool()
        let url = string("https://example.com/p", &rng)
        let fragment: FuzzJSON? = rng.oneIn(3) ? .string("#x") : rng.oneIn(4) ? .int(1) : nil
        let child = rng.oneIn(6)
        let frame: FuzzJSON? = rng.oneIn(8) ? FuzzJSON.random(&rng, notOf: [.object])
            : object(["url": url.0, "urlFragment": fragment, "parentId": child ? .string("p") : nil])
        let isReply = rng.oneIn(8)
        let text = try object([
            "method": .string(load ? "Page.loadEventFired" : "Page.frameNavigated"), "params": object(["frame": frame]),
            "id": isReply ? .int(3) : nil,
        ]).text()
        let event = ChromiumPageHostWire.documentEvent(text)
        let want: PageChromiumEvent?
        if isReply {
            want = nil
        } else if load {
            want = .finished
        } else if case .object? = frame, !child {
            var suffix = ""
            if case .string(let text)? = fragment { suffix = text }
            if case .string(let text)? = url.0 { want = .committed(URL(string: text + suffix)) } else { want = .committed(nil) }
        } else {
            want = nil
        }
        try FuzzRun.check(event == want, "\(text.prefix(300)) read as \(String(describing: event)), not \(String(describing: want))")
    }

    /// Any text through every reader of the wire: a value or nil, never a trap; an object read twice reads
    /// the same, each key once.
    static func anyText(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        _ = ChromiumPageHostWire.BindingCall(event: text)
        _ = ChromiumPageHostWire.Message(payload: text)
        _ = ChromiumPageHostWire.Sender(evaluation: text)
        _ = ChromiumPageHostWire.documentEvent(text)
        if let object = ChromiumPageHostWire.object(text) {
            let again = JSONValue(foundation: object)
            try FuzzRun.check(again != nil, "\(text.prefix(300)) read as an object no JSON holds")
        }
    }

    /// Seeds of ``anyText(_:)``: generated events, payloads and evaluations, and the equal-key payloads.
    static func seeds() -> [Data] {
        var rng = FuzzRNG(seed: 0xB41D_0179)
        var seeds = equalKeys.map { Data($0.utf8) }
        for _ in 0..<4 {
            let body = FuzzJSON.random(&rng, depth: 2)
            let payload = (try? object(["name": .string("cmuxPage"), "seq": .int(1), "body": body]).text()) ?? "{}"
            let event = object(["method": .string("Runtime.bindingCalled"),
                                "params": object(["name": .string("b"), "payload": .string(payload), "executionContextId": .int(4)])])
            seeds += [payload, event.description].map { Data($0.utf8) }
        }
        seeds.append(Data(#"{"result":{"value":["cmux://settings/",true]}}"#.utf8))
        seeds.append(Data(#"{"method":"Page.frameNavigated","params":{"frame":{"url":"https://a.b/","urlFragment":"#c"}}}"#.utf8))
        return seeds
    }

    /// One generated check of the wire.
    static func generated(_ rng: inout FuzzRNG) throws {
        switch rng.below(4) {
        case 0: try bindingCall(&rng)
        case 1: try message(&rng)
        case 2: try sender(&rng)
        default: try documentEvent(&rng)
        }
    }
}
