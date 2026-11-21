import CmuxVisibleRows
@testable import CmuxVisibleRowsTesting
import Testing

/// The contract itself, on two model lists with no UI: a windowed one (views for the rows in view and one viewport each
/// side, a change configures its row) passes; an eager one (a view per row, every change re-renders every row) breaks
/// rules 1 and 2, and is not built at 10,000.
@MainActor @Suite struct VisibleRowsContractSelfTests {
    @Test func aWindowedListMeetsTheContract() async throws {
        let measured = try await VisibleRowsContract.check(ModelRows<Windowed>.self)
        #expect(measured.map(\.rows) == [100, 10_000])
        #expect(measured.allSatisfy { $0.alive == 3 * ModelList.viewport })
    }

    @Test func anEagerListBreaksTheContractAndIsNotBuiltLarge() async throws {
        var measured: [VisibleRowsContract.Measurement] = []
        await withKnownIssue("an eager list mounts every row") {
            do { measured = try await VisibleRowsContract.check(ModelRows<Eager>.self) } catch { Issue.record(error) }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("row views") || $0.rawValue.contains("configured") }
        }
        #expect(measured.map(\.rows) == [100], "the eager list was built past the size where it failed")
        #expect(measured.first?.alive == 100)
        #expect(measured.first?.change.rowsConfigured == 100)
    }

    @Test func theBaselineNamesWhyAndWho() {
        for (name, known) in VisibleRowsBaseline.knownFailures {
            #expect(!name.isEmpty && known.why.contains("fix:"), "baseline line \(name) names no fixing lane")
        }
    }
}

@MainActor protocol ModelShape { static var eager: Bool { get } }
enum Windowed: ModelShape { static let eager = false }
enum Eager: ModelShape { static let eager = true }

/// A list with no views: it counts what a list of its shape would do.
@MainActor final class ModelList: VisibleRowsList {
    static let viewport = 20
    let listWork = ListWorkMeter()
    let count: Int, eager: Bool
    var top = 0
    var rowViewsAlive: Int { eager ? count : min(count, 3 * Self.viewport) }

    init(count: Int, eager: Bool) {
        (self.count, self.eager) = (count, eager)
        listWork.configured(rowViewsAlive)
    }

    func change() {
        listWork.configured(eager ? count : 1)
        listWork.walked(eager ? count : 1)
    }

    func scroll() {
        top += 1
        listWork.configured(eager ? 0 : 1)
        listWork.laidOut(eager ? count : 1)
    }

    func resize() { listWork.laidOut(rowViewsAlive) }
}

@MainActor final class ModelRows<Shape: ModelShape>: VisibleRowsFixture {
    static var name: String { Shape.eager ? "model eager list" : "model windowed list" }
    let list: ModelList
    init(rows: Int) async throws { list = ModelList(count: rows, eager: Shape.eager) }
    var viewportRows: Int { ModelList.viewport }
    func changeOneItem() async throws { list.change() }
    func scrollOneRow() async throws -> Bool { list.scroll(); return true }
    func resizeOneStep() async throws -> Bool { list.resize(); return true }
    func close() {}
}
