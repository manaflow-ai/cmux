import CmuxNextChiefMemory
import Foundation
import Testing

/// A brain stand-in: canned answers per path, every call recorded.
private actor FakeMemory: ChiefMemorySource {
    var calls: [(path: String, query: [String: String])] = []
    var answers: [String: String]
    var failures: [String: ChiefMemoryError] = [:]

    init(answers: [String: String] = FakeMemory.defaults) {
        self.answers = answers
    }

    static let defaults: [String: String] = [
        "/api/status": #"{"messages": 64, "nodes_built": 127, "stale": ["4+4"], "editable": true}"#,
        "/api/view": #"{"lines": [{"name": "0+32", "level": 5, "start": 0, "n": 32, "built": true, "text": "the start"}, {"name": "32+32", "level": 5, "start": 32, "n": 32, "built": true, "text": "later", "stale": true}]}"#,
        "/api/memory/changes": #"{"changes": [ {"id": 2, "at": "t2", "op": "delete", "target": {"node": "0+8"}, "old": "x", "new": "(deleted by the user)", "stale": [], "undone": true}, {"id": 1, "at": "t1", "op": "edit", "target": {"message": 5}, "old": "secret", "new": "fine", "stale": ["4+4"], "undone": false}], "stale": ["4+4"]}"#,
        "/api/node": #"{"name": "4+1", "level": 0, "start": 4, "n": 1, "built": true, "text": "user: hello", "message": {"id": 4, "kind": "user", "text": "hello there", "bytes": 11}}"#,
        "/api/search": #"{"hits": [{"type": "message", "id": 5, "kind": "user", "snippet": "my [secret]", "name": "5+1"}]}"#,
        "/api/memory/edit": #"{"id": 3}"#,
        "/api/memory/delete": #"{"id": 3}"#,
        "/api/memory/undo": #"{"id": 1}"#,
    ]

    func call(_ path: String, query: [String: String]) async throws(ChiefMemoryError) -> Data {
        calls.append((path, query))
        if let failure = failures[path] { throw failure }
        guard let answer = answers[path] else { throw .refused(status: 404, message: "no API \(path)") }
        return Data(answer.utf8)
    }

    func setFailure(_ failure: ChiefMemoryError, for path: String) {
        failures[path] = failure
    }

    /// The change paths called, with their queries.
    func changes() -> [(String, [String: String])] {
        calls.filter { $0.path.hasPrefix("/api/memory/") && $0.path != "/api/memory/changes" }.map { ($0.path, $0.query) }
    }
}

/// The person answering the delete dialog.
@MainActor
private final class Person {
    var asked: [ChiefMemoryTarget] = []
    var answer = false
}

@MainActor
@Suite struct ChiefMemoryInspectorModelTests {
    @Test func reloadReadsTheCountsTheViewAndTheChanges() async {
        let model = ChiefMemoryInspectorModel(source: FakeMemory(), confirmDelete: { _, _ in true })
        await model.reload()
        #expect(model.error == nil)
        #expect(model.status?.messages == 64)
        #expect(model.status?.editable == true)
        #expect(model.lines.map(\.name) == ["0+32", "32+32"])
        #expect(model.lines[1].stale)
        #expect(model.changes.map(\.id) == [2, 1])
        #expect(model.changes[1].target == .message(5))
        #expect(model.changes[0].target == .line("0+8"))
        #expect(model.isStale("4+4"))
    }

    @Test func openingALineZoomsAndBackReturns() async {
        let source = FakeMemory()
        let model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
        await model.open("0+8")
        await model.open("4+1")
        #expect(model.trail == ["0+8", "4+1"])
        #expect(model.detail?.message?.text == "hello there")
        #expect(model.text(of: .message(4)) == "hello there")
        await model.open("0+8")
        #expect(model.trail == ["0+8"], "opening a node on the trail cuts the trail there")
        await model.back()
        #expect(model.trail.isEmpty)
        #expect(model.detail == nil)
        let names = await source.calls.filter { $0.path == "/api/node" }.map { $0.query["name"] }
        #expect(names == ["0+8", "4+1", "0+8"])
    }

    @Test func anEditSendsTheTargetAndTextThenReadsAgain() async {
        let source = FakeMemory()
        let model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
        await model.open("4+1")
        model.beginEdit(.message(4))
        #expect(model.draft == "hello there", "the edit starts from the current text")
        model.draft = "hello, edited"
        await model.saveEdit()
        #expect(model.editing == nil)
        let changes = await source.changes()
        #expect(changes.count == 1)
        #expect(changes.first?.0 == "/api/memory/edit")
        #expect(changes.first?.1 == ["target": "message:4", "text": "hello, edited"])
        #expect(model.status != nil, "read again after the change")

        // A cancelled edit sends nothing.
        model.beginEdit(.line("4+1"))
        #expect(model.draft == "user: hello")
        model.cancelEdit()
        #expect(await source.changes().count == 1)
    }

    @Test func aDeleteWaitsForItsConfirmation() async {
        let source = FakeMemory()
        let person = Person()
        let model = ChiefMemoryInspectorModel(source: source) { target, _ in
            person.asked.append(target)
            return person.answer
        }
        await model.delete(.line("0+8"))
        #expect(person.asked == [.line("0+8")], "the person is asked first")
        #expect(await source.changes().isEmpty, "a no deletes nothing")

        person.answer = true
        await model.delete(.message(5))
        let changes = await source.changes()
        #expect(changes.map(\.0) == ["/api/memory/delete"])
        #expect(changes.first?.1 == ["target": "message:5"])
    }

    @Test func undoLastUndoesTheNewestChangeNotYetUndone() async {
        let source = FakeMemory()
        let model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
        await model.reload()
        await model.undoLast()
        let changes = await source.changes()
        #expect(changes.map(\.0) == ["/api/memory/undo"])
        #expect(changes.first?.1 == ["change": "1"], "change 2 is already undone")
        await model.undo(2)
        #expect(await source.changes().last?.1 == ["change": "2"])
    }

    @Test func aRefusedChangeShowsWhyAndKeepsTheEdit() async {
        let source = FakeMemory()
        await source.setFailure(ChiefMemoryError.refused(status: 400, message: "the new text is 600 bytes; at most 512 fit here"), for: "/api/memory/edit")
        let model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
        await model.open("4+1")
        model.beginEdit(.line("4+1"))
        model.draft = String(repeating: "x", count: 600)
        await model.saveEdit()
        #expect(model.error == "the new text is 600 bytes; at most 512 fit here")
        #expect(model.editing == .line("4+1"), "the draft is kept to fix")
    }

    @Test func anUnreachableChiefSaysSo() async {
        let source = FakeMemory()
        await source.setFailure(ChiefMemoryError.unreachable, for: "/api/status")
        let model = ChiefMemoryInspectorModel(source: source, confirmDelete: { _, _ in true })
        await model.reload()
        #expect(model.error?.isEmpty == false)
        #expect(model.status == nil)
    }

    @Test func targetsNameTheChangePathsQuery() {
        #expect(ChiefMemoryTarget.message(42).queryValue == "message:42")
        #expect(ChiefMemoryTarget.line("0+8").queryValue == "node:0+8")
    }
}
