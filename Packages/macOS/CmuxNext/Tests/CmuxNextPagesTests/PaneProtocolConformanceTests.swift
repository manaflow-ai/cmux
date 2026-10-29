@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Swift runner of the oracle's pane-protocol suite: `tests/oracle/corpus/pane-protocol/`,
/// written by `scripts/cmux-next/oracle/gen_pane_protocol.py`, which the Rust runner (cmux-pane-protocol's
/// `conformance` example) and the TS runner (`webviews/scripts/pane-protocol-conformance.ts`) read too, as every
/// Mojo binding reads chromium/src `mojo/public/interfaces/bindings/tests/data/validation/`.
///
/// ``PageRouter`` is the Swift side of the protocol, so this runs the envelopes a page can send it. Each reply is one
/// of three outcomes (``Outcome``): accepted (`ok` to a `call` or `sub`, no reply to `unsub`, `cancel`, `ok` and
/// `err`), refused (an `err` with `invalid_params` or `bad_message`, or text that is not JSON), or any other reply,
/// which fails the case whatever it expects. A `valid` case must be accepted, an `invalid` one refused, and one that
/// names a `session_refusal` refused with that code. `_expectations.json` lists the cases Swift skips and its known
/// divergences; any other mismatch fails, and a listed divergence that conforms is an unexpected pass, recorded
/// without failing (Blink's TestExpectations rule). Run: `swift test --filter PaneProtocolConformanceTests`.
@MainActor
struct PaneProtocolConformanceTests {
    private static let descriptor = PageDescriptor(id: "cmux.conformance", resource: "conformance", processGroup: .solo,
                                                   namespaces: ["cmux.git."])
    private static let refusalCodes: Set<String> = ["cmux.protocol.invalid_params", "cmux.protocol.bad_message"]
    private static let categories = ["envelopes", "frames", "tokens", "credit"]

    /// Answers every call and subscription under `cmux.git.`, so only the router's own checks refuse.
    final class AcceptingProvider: PageProvider {
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            PageSubscription(frozenDelivery: .latest) {}
        }
    }

    private static var corpus: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/oracle/corpus/pane-protocol")
    }

    private static func read(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: corpus.appendingPathComponent(name)))
    }

    private static func swiftPlan() throws -> JSONValue {
        let expectations = try read("_expectations.json")
        return try #require(expectations["implementations"]?["swift"])
    }

    /// What a fresh router did with one message.
    enum Outcome: Equatable {
        /// `ok` to a `call` or `sub`; no reply to the kinds that take none.
        case accepted
        /// An `err` with a refusal code; nil code when the text is not JSON, which the bridge drops.
        case refused(code: String?)
        /// Any other reply: an `err` with another code, or the wrong kind of answer.
        case unexpected(String)

        var description: String {
            switch self {
            case .accepted: "accepted"
            case .refused(let code): "refused (\(code ?? "not JSON"))"
            case .unexpected(let reply): "answered \(reply)"
            }
        }
    }

    /// The kinds a router answers with no reply (`PageRouter.handle`).
    private static let unansweredKinds: Set<String> = ["unsub", "cancel", "ok", "err"]

    /// What a fresh router does with `text` as a page's message of kind `kind` (the corpus's `t`).
    private static func outcome(of text: String, kind: String?) async -> Outcome {
        guard let message = try? JSONValue.parse(Data(text.utf8)) else { return .refused(code: nil) }
        let route = PageRoute(prefix: "cmux.git.", provider: AcceptingProvider())
        let router = PageRouter(descriptor: descriptor, routes: [route])
        router.send = { _ in }
        let reply = await router.handle(message)
        router.close()
        if reply["t"]?.stringValue == "err" {
            let code = reply["code"]?.stringValue ?? "no code"
            return refusalCodes.contains(code) ? .refused(code: code) : .unexpected("err \(code)")
        }
        if let kind, unansweredKinds.contains(kind) {
            return reply == .null ? .accepted : .unexpected(reply.prettyText())
        }
        return reply["t"]?.stringValue == "ok" ? .accepted : .unexpected(reply.prettyText())
    }

    /// Whether `outcome` is what the case expects: its `session_refusal` code, any refusal for `invalid`, else accepted.
    private static func conforms(_ outcome: Outcome, verdict: String?, sessionRefusal: String?) -> Bool {
        if let sessionRefusal { return outcome == .refused(code: sessionRefusal) }
        if verdict == "invalid" {
            if case .refused = outcome { return true }
            return false
        }
        return outcome == .accepted
    }

    @Test func everyCategoryThisRunnerRunsIsEnvelopes() throws {
        let plan = try Self.swiftPlan()
        for category in Self.categories {
            let decision = try #require(plan["categories"]?[category]?.stringValue, "\(category) has no Swift plan")
            #expect((decision == "run") == (category == "envelopes"), "\(category): \(decision)")
        }
    }

    @Test func pageRouterAnswersEveryEnvelopeAsTheCorpusSays() async throws {
        let plan = try Self.swiftPlan()
        let skip = plan["skip"]?.objectValue ?? [:]
        let divergences = plan["divergences"]?.objectValue ?? [:]
        let envelopes = try Self.read("_envelopes.json")
        let cases = try #require(envelopes["cases"]?.arrayValue)
        var ran = 0
        var known = 0
        for test in cases {
            let id = try #require(test["id"]?.stringValue)
            guard skip[id] == nil else { continue }
            let text = try #require(test["text"]?.stringValue, "\(id) has no text")
            let verdict = test["verdict"]?.stringValue
            let sessionRefusal = test["session_refusal"]?.stringValue
            let outcome = await Self.outcome(of: text, kind: test["kind"]?.stringValue)
            ran += 1
            if case .unexpected = outcome {
                Issue.record("\(id): PageRouter \(outcome.description) to \(text)")
                continue
            }
            switch (Self.conforms(outcome, verdict: verdict, sessionRefusal: sessionRefusal), divergences[id]) {
            case (true, .none):
                break
            case (true, .some(let listed)):
                let bug = listed["bug"]?.stringValue ?? "?"
                print("UNEXPECTED PASS \(id): conforms; remove its divergence (\(bug))")
            case (false, .none):
                let want = sessionRefusal.map { "refused (\($0))" } ?? (verdict == "invalid" ? "refused" : "accepted")
                Issue.record("\(id): PageRouter \(outcome.description), want \(want): \(text)")
            case (false, .some):
                known += 1
            }
        }
        #expect(ran > 0, "no envelope ran")
        print("pane-protocol conformance (swift): \(ran) ran, \(known) known divergences, \(skip.count) skipped")
    }
}
