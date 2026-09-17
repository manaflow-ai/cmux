import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareTextDocumentTests {
    @Test
    func concurrentJapaneseAndEmojiEditsConverge() {
        let snapshot = WorkspaceShareTextDocument(docId: "doc", text: "start ").snapshot
        var alice = WorkspaceShareTextDocument(snapshot: snapshot)
        var bob = WorkspaceShareTextDocument(snapshot: snapshot)
        var aliceCounter: UInt64 = 0
        var bobCounter: UInt64 = 0
        let aliceOperations = alice.localChange(to: "start 🙂", clientID: "alice", counter: &aliceCounter)
        let bobOperations = bob.localChange(to: "start 日本", clientID: "bob", counter: &bobCounter)

        for operation in bobOperations { alice.apply(operation) }
        for operation in aliceOperations { bob.apply(operation) }

        #expect(alice.text == bob.text)
        #expect(alice.text.contains("🙂"))
        #expect(alice.text.contains("日本"))
    }

    @Test
    func deleteBeforeInsertStaysDeleted() {
        var document = WorkspaceShareTextDocument(docId: "doc", text: "")
        let insert = WorkspaceShareTextOperation.insert(
            opId: id(2, "alice"),
            docId: "doc",
            atoms: [WorkspaceShareTextAtom(id: id(1, "alice"), afterId: nil, value: "🙂")]
        )
        let delete = WorkspaceShareTextOperation.delete(
            opId: id(1, "bob"),
            docId: "doc",
            atomIds: [id(1, "alice")]
        )
        document.apply(delete)
        document.apply(insert)
        #expect(document.text.isEmpty)
    }

    @Test
    func duplicateOperationIsIdempotent() {
        var document = WorkspaceShareTextDocument(docId: "doc", text: "a")
        let operation = WorkspaceShareTextOperation.insert(
            opId: id(3, "alice"),
            docId: "doc",
            atoms: [WorkspaceShareTextAtom(
                id: id(2, "alice"),
                afterId: id(1, "host"),
                value: "b"
            )]
        )
        let firstApply = document.apply(operation)
        let secondApply = document.apply(operation, acceptedRevision: 9)
        #expect(firstApply)
        #expect(!secondApply)
        #expect(document.text == "ab")
        #expect(document.revision == 9)
    }

    @Test
    func middleInsertionStaysBeforeExistingSuffix() {
        var document = WorkspaceShareTextDocument(docId: "doc", text: "abc")
        var counter: UInt64 = 0
        _ = document.localChange(to: "a🙂bc", clientID: "alice", counter: &counter)
        #expect(document.text == "a🙂bc")
    }

    @Test
    func largeReplacementUsesBoundedOperations() {
        var document = WorkspaceShareTextDocument(docId: "doc", text: "")
        var counter: UInt64 = 0
        let text = String(repeating: "x", count: 600)
        let operations = document.localChange(to: text, clientID: "alice", counter: &counter)
        #expect(operations.count == 3)
        #expect(operations.allSatisfy { ($0.atoms?.count ?? 0) <= WorkspaceShareTextDocument.maximumOperationAtoms })
        #expect(document.text == text)
    }

    @Test
    func rootAtomUsesCanonicalWireFields() throws {
        let operation = WorkspaceShareTextOperation.insert(
            opId: id(2, "host"),
            docId: "doc",
            atoms: [WorkspaceShareTextAtom(id: id(1, "host"), afterId: nil, value: "x")]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any]
        )
        let atoms = try #require(object["atoms"] as? [[String: Any]])
        let atom = try #require(atoms.first)
        #expect(atom["afterId"] is NSNull)
        #expect(atom["deleted"] as? Bool == false)
    }

    @Test
    func hostileRemoteClockCannotPoisonLocalEdits() {
        var document = WorkspaceShareTextDocument(docId: "doc", text: "a")
        let hostile = WorkspaceShareTextOperation.delete(
            opId: "999999999999:viewer",
            docId: "doc",
            atomIds: [id(1, "host")]
        )
        let accepted = document.apply(hostile)
        #expect(!accepted)

        var counter: UInt64 = 0
        let operations = document.localChange(to: "ab", clientID: "host", counter: &counter)
        #expect(!operations.isEmpty)
        #expect(document.text == "ab")
    }

    @Test
    func boundedRemoteClockAndParticipantNamespaceProtectHostIdentifiers() {
        var document = WorkspaceShareTextDocument(docId: "doc", text: "a")
        let jumped = WorkspaceShareTextOperation.insert(
            opId: id(999_999_999, "viewer"),
            docId: "doc",
            atoms: [WorkspaceShareTextAtom(id: id(999_999_998, "viewer"), afterId: nil, value: "x")]
        )
        let acceptedJump = document.apply(jumped, expectedClientID: "viewer")
        #expect(!acceptedJump)

        let spoofed = WorkspaceShareTextOperation.insert(
            opId: id(3, "host"),
            docId: "doc",
            atoms: [WorkspaceShareTextAtom(id: id(2, "host"), afterId: id(1, "host"), value: "x")]
        )
        let acceptedSpoof = document.apply(spoofed, expectedClientID: "viewer")
        #expect(!acceptedSpoof)
        #expect(document.text == "a")
    }

    private func id(_ clock: Int, _ client: String) -> String {
        String(format: "%012d", clock) + ":" + client
    }
}
