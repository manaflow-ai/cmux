import Testing
@testable import CmuxBrowser

/// Records native find calls and lets a test answer them like Chromium's find-result events.
@MainActor
private final class FakeNativeFindDriver: BrowserNativeFindDriving {
    struct Call: Equatable {
        let text: String
        let forward: Bool
        let matchCase: Bool
        let findNext: Bool
    }

    private(set) var calls: [Call] = []
    private(set) var stops: [Bool] = []
    var onFind: ((Call) -> Void)?
    /// Yields each call after it is recorded, so a test can wait for a request to reach the engine.
    let issued: AsyncStream<Call>
    private let issuedContinuation: AsyncStream<Call>.Continuation

    init() {
        (issued, issuedContinuation) = AsyncStream.makeStream()
    }

    var canFind = true

    func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) -> Bool {
        let call = Call(text: text, forward: forward, matchCase: matchCase, findNext: findNext)
        calls.append(call)
        guard canFind else { return false }
        issuedContinuation.yield(call)
        onFind?(call)
        return true
    }

    func stopFinding(clearSelection: Bool) {
        stops.append(clearSelection)
    }
}

@MainActor
@Suite struct BrowserNativeFindSessionTests {
    @Test func searchAnswersWithTheFinalResultOnly() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        driver.onFind = { [weak session] _ in
            session?.receiveResult(count: 2, activeOrdinal: 1, isFinal: false)
            session?.receiveResult(count: 4, activeOrdinal: 1, isFinal: true)
        }
        let count = await session.search(needle: "cmux")
        #expect(count == BrowserFindMatchCount(total: 4, selected: 0))
        #expect(driver.calls == [.init(text: "cmux", forward: true, matchCase: false, findNext: false)])
        #expect(!session.hasPendingRequest)
    }

    @Test func nextAndPreviousStepFromTheActiveMatch() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        var ordinal = 1
        driver.onFind = { [weak session] call in
            if call.findNext { ordinal += call.forward ? 1 : -1 }
            session?.receiveResult(count: 3, activeOrdinal: ordinal, isFinal: true)
        }
        _ = await session.search(needle: "a")
        #expect(await session.next() == BrowserFindMatchCount(total: 3, selected: 1))
        #expect(await session.previous() == BrowserFindMatchCount(total: 3, selected: 0))
        #expect(driver.calls.map(\.findNext) == [false, true, true])
        #expect(driver.calls.map(\.forward) == [true, true, false])
    }

    @Test func emptyNeedleAndStepsWithoutSearchDoNotRun() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        #expect(await session.search(needle: "") == nil)
        #expect(await session.next() == nil)
        #expect(await session.previous() == nil)
        #expect(driver.calls.isEmpty)
    }

    @Test func aNewRequestAnswersThePendingOneWithNil() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        var issued = driver.issued.makeAsyncIterator()
        let first = Task { await session.search(needle: "first") }
        _ = await issued.next()
        driver.onFind = { [weak session] _ in session?.receiveResult(count: 1, activeOrdinal: 1, isFinal: true) }
        let second = await session.search(needle: "second")
        #expect(await first.value == nil)
        #expect(second == BrowserFindMatchCount(total: 1, selected: 0))
    }

    @Test func clearStopsFindingKeepsSelectionAndForgetsTheNeedle() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        driver.onFind = { [weak session] _ in session?.receiveResult(count: 1, activeOrdinal: 1, isFinal: true) }
        _ = await session.search(needle: "x")
        await session.clear()
        #expect(driver.stops == [false])
        #expect(session.currentNeedle.isEmpty)
        #expect(await session.next() == nil)
    }

    @Test func theSameNeedleStepsUnlessTheDocumentChanged() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        driver.onFind = { [weak session] _ in session?.receiveResult(count: 1, activeOrdinal: 1, isFinal: true) }
        _ = await session.search(needle: "x")
        _ = await session.search(needle: "x")
        session.resetForNewDocument()
        _ = await session.search(needle: "x")
        #expect(driver.calls.map(\.findNext) == [false, true, false])
    }

    @Test func stepsAfterANewDocumentStartAFreshSearchForTheSameNeedle() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        driver.onFind = { [weak session] _ in session?.receiveResult(count: 1, activeOrdinal: 1, isFinal: true) }
        _ = await session.search(needle: "x")
        session.resetForNewDocument()
        #expect(session.currentNeedle == "x")
        #expect(await session.next() == BrowserFindMatchCount(total: 1, selected: 0))
        _ = await session.next()
        session.resetForNewDocument()
        _ = await session.previous()
        #expect(driver.calls.map(\.text) == ["x", "x", "x", "x"])
        #expect(driver.calls.map(\.findNext) == [false, false, true, false])
    }

    @Test func cancelPendingAnswersWithNil() async {
        let driver = FakeNativeFindDriver()
        let session = BrowserNativeFindSession(driver: driver)
        var issued = driver.issued.makeAsyncIterator()
        let pending = Task { await session.search(needle: "slow") }
        _ = await issued.next()
        #expect(session.hasPendingRequest)
        session.cancelPending()
        #expect(await pending.value == nil)
    }

    @Test func anEngineThatCannotSearchAnswersAtOnce() async {
        let driver = FakeNativeFindDriver()
        driver.canFind = false
        let session = BrowserNativeFindSession(driver: driver)
        #expect(await session.search(needle: "x") == nil)
        #expect(!session.hasPendingRequest)
    }

    @Test func matchCountMapsChromiumOrdinals() {
        #expect(BrowserNativeFindSession.matchCount(count: 0, activeOrdinal: 0) == BrowserFindMatchCount(total: 0, selected: nil))
        #expect(BrowserNativeFindSession.matchCount(count: -1, activeOrdinal: 3) == BrowserFindMatchCount(total: 0, selected: nil))
        #expect(BrowserNativeFindSession.matchCount(count: 5, activeOrdinal: 5) == BrowserFindMatchCount(total: 5, selected: 4))
        #expect(BrowserNativeFindSession.matchCount(count: 5, activeOrdinal: 0) == BrowserFindMatchCount(total: 5, selected: 0))
        #expect(BrowserNativeFindSession.matchCount(count: 5, activeOrdinal: 9) == BrowserFindMatchCount(total: 5, selected: 4))
    }
}
