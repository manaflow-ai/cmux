import CmuxFuzzSupport
import CmuxNextSettings
import Foundation
@testable import CmuxNextPages

/// A provider for the fuzz page's namespace: it records each call and stream, answers `{op}`, refuses
/// `cmux.fuzz.fail` with a ``PageError`` and `cmux.fuzz.boom` with another error.
final class PageBridgeFuzzProvider: PageProvider {
    nonisolated struct Boom: Error {}

    var calls: [String] = []
    var streams: [String] = []

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        calls.append(op)
        switch op {
        case "cmux.fuzz.fail": throw PageError(code: "cmux.fuzz.refused", message: "refused")
        case "cmux.fuzz.boom": throw Boom()
        default: return ["op": .string(op)]
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        streams.append(stream)
        if stream == "cmux.fuzz.failstream" { throw PageError(code: "cmux.fuzz.refused", message: "refused") }
        return PageSubscription(frozenDelivery: .latest) {}
    }
}

/// The checks of the page bridge suite.
enum PageBridgeCase {
    static let location = "PageBridgeFuzzTests"
    static let descriptor = PageDescriptor(id: "cmux.fuzz-bridge", resource: "fuzz-bridge", processGroup: .solo,
                                           namespaces: [PageBridgeEnvelopes.namespace])

    /// A page's router on the fuzz provider, and the ids of the host calls it sends the page, in order.
    struct Page {
        let provider: PageBridgeFuzzProvider
        let router: PageRouter
        let hostCalls: AsyncStream<UInt64>

        init() {
            let provider = PageBridgeFuzzProvider()
            self.provider = provider
            router = PageRouter(descriptor: PageBridgeCase.descriptor,
                                routes: [PageRoute(prefix: PageBridgeEnvelopes.namespace, provider: provider)])
            let (hostCalls, sink) = AsyncStream.makeStream(of: UInt64.self)
            self.hostCalls = hostCalls
            router.send = { envelope in
                if envelope["t"]?.stringValue == "call", let id = envelope["id"]?.doubleValue { sink.yield(UInt64(id)) }
            }
        }
    }

    typealias HostResult = Result<String, PageError>

    /// Envelopes in any order (calls, subscriptions, cancels, replies to host calls that are pending, answered,
    /// or never made, with ids no counter reaches): each gets the reply the router's contract names; only
    /// admitted ops reach the provider; each malformed envelope is counted once; each host call ends with the
    /// page's own reply to it, or closed; and the page still answers a good call afterwards.
    static func router(_ rng: inout FuzzRNG) async throws {
        let page = Page()
        var model = PageBridgeModel()
        var calls: [(id: UInt64, task: Task<HostResult, Never>)] = []
        var expected: [UInt64: HostResult] = [:]
        for _ in 0..<(4 + rng.below(28)) {
            if rng.oneIn(8) {
                let router = page.router
                let task = Task { @MainActor () -> HostResult in
                    do {
                        return .success(try await router.callPage("cmux.page.ping", params: .object([:])).compactText)
                    } catch let error as PageError {
                        return .failure(error)
                    } catch {
                        return .failure(PageError(code: "unexpected", message: String(describing: error)))
                    }
                }
                guard let id = await next(page.hostCalls) else { throw FuzzError.property("no host call", location: location) }
                calls.append((id, task))
                continue
            }
            let envelope = rng.oneIn(4) ? hostReply(&rng, pending: calls.map(\.id)) : PageBridgeEnvelopes.envelope(&rng)
            if let type = envelope["t"]?.stringValue, type == "ok" || type == "err", let number = envelope["id"]?.doubleValue,
               PageBridgeModel.isCounter(number), calls.contains(where: { $0.id == UInt64(max(0, number)) }),
               expected[UInt64(max(0, number))] == nil {
                expected[UInt64(max(0, number))] = type == "ok"
                    ? .success((envelope["value"] ?? .null).compactText)
                    : .failure(PageError(code: envelope["code"]?.stringValue ?? "cmux.page.failed", message: envelope["message"]?.stringValue ?? ""))
            }
            let want = model.reply(to: envelope)
            let reply = await page.router.handle(envelope)
            try FuzzRun.check(PageBridgeModel.matches(reply, want),
                              "\(envelope.compactText.prefix(400)) got \(reply.compactText.prefix(400)), the contract says \(want)")
        }
        try FuzzRun.check(page.router.badMessages == model.bad, "the router counted \(page.router.badMessages) bad messages, the model \(model.bad)")
        try FuzzRun.check(page.provider.calls == model.calls, "the provider got calls \(page.provider.calls), the model \(model.calls)")
        try FuzzRun.check(page.provider.streams == model.streams, "the provider got streams \(page.provider.streams), the model \(model.streams)")
        let live = await page.router.handle(["t": "call", "id": 99, "op": "cmux.fuzz.echo"])
        try FuzzRun.check(PageBridgeModel.matches(live, .ok(99, ["op": "cmux.fuzz.echo"])), "the page is not live: \(live.compactText)")
        page.router.close()
        for call in calls {
            let got = await call.task.value
            let want = expected[call.id] ?? .failure(PageError.closed)
            try FuzzRun.check(same(got, want), "host call \(call.id) ended \(got), the page's reply says \(want)")
        }
    }

    /// The next host call the router sent the page.
    static func next(_ hostCalls: AsyncStream<UInt64>) async -> UInt64? {
        for await id in hostCalls { return id }
        return nil
    }

    /// The page's reply to a host call: to a pending call's id, or to one that is no call.
    static func hostReply(_ rng: inout FuzzRNG, pending: [UInt64]) -> JSONValue {
        let id: JSONValue = rng.oneIn(4) || pending.isEmpty ? PageBridgeEnvelopes.number(&rng) : .number(Double(rng.element(of: pending) ?? 0))
        var fields: [String: JSONValue] = ["t": rng.bool() ? "ok" : "err", "id": id]
        if !rng.oneIn(4) { fields["value"] = PageBridgeEnvelopes.value(&rng) }
        if rng.bool() { fields["code"] = rng.oneIn(4) ? PageBridgeEnvelopes.value(&rng, depth: 0) : .string("cmux.page.refused") }
        if rng.bool() { fields["message"] = .string(FuzzJSON.randomString(&rng)) }
        return .object(fields)
    }

    private static func same(_ got: HostResult, _ want: HostResult) -> Bool {
        switch (got, want) {
        case (.success(let a), .success(let b)): a == b
        case (.failure(let a), .failure(let b)): a.code == b.code
        default: false
        }
    }

    // MARK: Bodies

    /// Any body an engine hands over: read as JSON (or refused and counted) as ``PageFuzzBody/bridged`` says,
    /// through the router and the readiness script's handler without a trap, and its reply written for a
    /// Chromium page as JSON or the invalid-reply envelope.
    static func bodies(_ rng: inout FuzzRNG, page: Page, readiness: PageInputReadiness) async throws {
        let body = PageFuzzBody.random(&rng)
        let foundation = body.foundation
        try bridge(body)
        let before = page.router.badMessages
        let value = page.router.envelope(foundation)
        let bridged = body.bridged
        try FuzzRun.check(page.router.badMessages == before + (bridged.accepted ? 0 : 1), "a refused body counted \(page.router.badMessages - before) times")
        if let value {
            let reply = await page.router.handle(value)
            try FuzzRun.check(reply.isNull || ["ok", "err"].contains(reply["t"]?.stringValue ?? ""), "\(value.compactText.prefix(400)) got \(reply.compactText.prefix(400))")
        }
        let readinessBefore = readiness.badMessages
        readiness.receive(foundation)
        try FuzzRun.check(readiness.badMessages == readinessBefore + (bridged.accepted ? 0 : 1), "the readiness handler counted \(readiness.badMessages - readinessBefore)")
    }

    /// The nonisolated part of ``bodies(_:page:readiness:)``: the JSON reading and the Chromium reply.
    nonisolated static func bridge(_ body: PageFuzzBody) throws {
        let foundation = body.foundation
        let value = JSONValue(foundation: foundation)
        let bridged = body.bridged
        try FuzzRun.check((value != nil) == bridged.accepted, "\(body) read as \(value?.compactText.prefix(200) ?? "nothing")")
        if let exact = bridged.exact {
            try FuzzRun.check(value?.compactText == exact.compactText, "\(body) read as \(value?.compactText.prefix(200) ?? "-")")
        }
        let expression = ChromiumPageHostWire.resolveExpression(seq: 3, reply: foundation)
        let prefix = "globalThis.\(ChromiumPageHostBridge.resolveName)?.(3, "
        try FuzzRun.check(expression.hasPrefix(prefix) && expression.hasSuffix(");"), "the reply call \(expression.prefix(200))")
        let written = String(expression.dropFirst(prefix.count).dropLast(2))
        let parsed = try? JSONSerialization.jsonObject(with: Data(written.utf8), options: [.fragmentsAllowed])
        try FuzzRun.check(parsed != nil, "the reply call writes no JSON: \(written.prefix(200))")
        let invalid = written.contains("native.invalid_reply")
        if case .null = body {
            try FuzzRun.check(written == "null", "a null reply written as \(written.prefix(200))")
        } else {
            try FuzzRun.check(invalid == !body.serializable, "a reply of \(body) written as \(written.prefix(200))")
        }
    }
}
