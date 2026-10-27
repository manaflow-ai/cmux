@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Swift runner of the oracle's pane-protocol suite (p15-oracle-213): `tests/oracle/corpus/pane-protocol/`,
/// written by `scripts/cmux-next/oracle/gen_pane_protocol.py`, which the Rust runner (cmux-pane-protocol's
/// `conformance` example) and the TS runner (`webviews/scripts/pane-protocol-conformance.ts`) read too, as every
/// Mojo binding reads chromium/src `mojo/public/interfaces/bindings/tests/data/validation/`.
///
/// ``PageRouter`` is the Swift side of the protocol, so this runs the envelopes a page can send it: an envelope is
/// refused when the router answers `invalid_params` or `bad_message`, and a case expects that when its verdict is
/// `invalid` or it names a `session_refusal`. `_expectations.json` lists the cases Swift skips and its known
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

    /// Whether a fresh router refuses `text` as a page's message.
    private static func refuses(_ text: String) async -> Bool {
        guard let message = try? JSONValue.parse(Data(text.utf8)) else { return true }
        let route = PageRoute(prefix: "cmux.git.", provider: AcceptingProvider())
        let router = PageRouter(descriptor: descriptor, routes: [route])
        router.send = { _ in }
        let reply = await router.handle(message)
        router.close()
        guard reply["t"]?.stringValue == "err", let code = reply["code"]?.stringValue else { return false }
        return refusalCodes.contains(code)
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
            let expectsRefusal = test["verdict"]?.stringValue == "invalid" || test["session_refusal"] != nil
            let refused = await Self.refuses(text)
            ran += 1
            switch (refused == expectsRefusal, divergences[id]) {
            case (true, .none):
                break
            case (true, .some(let listed)):
                let bug = listed["bug"]?.stringValue ?? "?"
                print("UNEXPECTED PASS \(id): conforms; remove its divergence (\(bug))")
            case (false, .none):
                Issue.record("\(id): PageRouter \(refused ? "refused" : "accepted") \(text)")
            case (false, .some):
                known += 1
            }
        }
        #expect(ran > 0, "no envelope ran")
        print("pane-protocol conformance (swift): \(ran) ran, \(known) known divergences, \(skip.count) skipped")
    }
}
