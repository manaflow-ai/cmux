import Testing
@testable import CmuxBrowser

/// A fake script evaluator that records the scripts it ran and returns canned results.
@MainActor
private final class FakeEvaluator: BrowserFindScriptEvaluating {
    enum Outcome {
        case value(Any?)
        case failure(Error)
    }

    struct EvaluatorError: Error {}

    private(set) var evaluated: [BrowserFindScript] = []
    var nextOutcome: Outcome = .value(nil)

    func evaluate(_ script: BrowserFindScript) async throws -> Any? {
        evaluated.append(script)
        switch nextOutcome {
        case .value(let value): return value
        case .failure(let error): throw error
        }
    }
}

@MainActor
@Suite struct BrowserFindServiceTests {
    @Test func searchParsesMatchCount() async {
        let evaluator = FakeEvaluator()
        evaluator.nextOutcome = .value("{\"total\":3,\"current\":0}")
        let service = BrowserFindService(evaluator: evaluator)

        let count = await service.search(needle: "hello")

        #expect(count == BrowserFindMatchCount(total: 3, selected: 0))
        #expect(evaluator.evaluated.count == 1)
        #expect(evaluator.evaluated[0].source.contains("const query = \"hello\""))
    }

    @Test func emptyNeedleDoesNotEvaluate() async {
        let evaluator = FakeEvaluator()
        let service = BrowserFindService(evaluator: evaluator)

        let count = await service.search(needle: "")

        #expect(count == nil)
        #expect(evaluator.evaluated.isEmpty)
    }

    @Test func searchErrorLeavesCountUntouched() async {
        let evaluator = FakeEvaluator()
        evaluator.nextOutcome = .failure(FakeEvaluator.EvaluatorError())
        let service = BrowserFindService(evaluator: evaluator)

        let count = await service.search(needle: "hello")

        #expect(count == nil)
        #expect(evaluator.evaluated.count == 1)
    }

    @Test func nextRunsNextScriptAndParses() async {
        let evaluator = FakeEvaluator()
        evaluator.nextOutcome = .value("{\"total\":5,\"current\":2}")
        let service = BrowserFindService(evaluator: evaluator)

        let count = await service.next()

        #expect(count == BrowserFindMatchCount(total: 5, selected: 2))
        #expect(evaluator.evaluated.count == 1)
        #expect(evaluator.evaluated[0] == BrowserFindScript.next())
    }

    @Test func previousSwallowsErrorsAsNil() async {
        let evaluator = FakeEvaluator()
        evaluator.nextOutcome = .failure(FakeEvaluator.EvaluatorError())
        let service = BrowserFindService(evaluator: evaluator)

        let count = await service.previous()

        #expect(count == nil)
    }

    @Test func clearRunsClearScript() async {
        let evaluator = FakeEvaluator()
        evaluator.nextOutcome = .value("ok")
        let service = BrowserFindService(evaluator: evaluator)

        await service.clear()

        #expect(evaluator.evaluated.count == 1)
        #expect(evaluator.evaluated[0] == BrowserFindScript.clear())
    }
}

@Suite struct BrowserFindMatchCountTests {
    @Test func parsesValidPayload() {
        let count = BrowserFindMatchCount.parse("{\"total\":4,\"current\":1}")
        #expect(count == BrowserFindMatchCount(total: 4, selected: 1))
    }

    @Test func reportsNilSelectedWhenNoMatches() {
        let count = BrowserFindMatchCount.parse("{\"total\":0,\"current\":0}")
        #expect(count == BrowserFindMatchCount(total: 0, selected: nil))
    }

    @Test func rejectsNonStringInput() {
        #expect(BrowserFindMatchCount.parse(42) == nil)
        #expect(BrowserFindMatchCount.parse(nil) == nil)
    }

    @Test func rejectsNegativeCounts() {
        #expect(BrowserFindMatchCount.parse("{\"total\":-1,\"current\":0}") == nil)
    }

    @Test func rejectsMalformedJSON() {
        #expect(BrowserFindMatchCount.parse("not json") == nil)
        #expect(BrowserFindMatchCount.parse("{\"total\":1}") == nil)
    }
}

@Suite struct BrowserFindScriptTests {
    @Test func searchEscapesQuotes() {
        let script = BrowserFindScript.search(query: "a\"b\\c")
        #expect(script.source.contains("const query = \"a\\\"b\\\\c\""))
    }

    @Test func emptyQueryStillBuildsValidScript() {
        let script = BrowserFindScript.search(query: "")
        #expect(script.source.contains("const query = \"\""))
    }
}
