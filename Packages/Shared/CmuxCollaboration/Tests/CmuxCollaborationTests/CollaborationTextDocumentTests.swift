import CmuxCollaboration
import Testing

@Suite
struct CollaborationTextDocumentTests {
    @Test
    func concurrentEditsConvergeInDifferentOrders() {
        let author = CollaborationTextDocument(text: "abcd", peerID: "a")
        var left = CollaborationTextDocument(peerID: "b")
        var right = CollaborationTextDocument(peerID: "c")
        let bootstrap = author.snapshotOperations()
        left.merge(bootstrap)
        right.merge(bootstrap)

        let leftOps = left.replace(range: 1..<3, with: "XY")
        let rightOps = right.replace(range: 2..<2, with: "!")

        var replicaOne = CollaborationTextDocument(peerID: "one")
        replicaOne.merge(bootstrap)
        replicaOne.merge(leftOps)
        replicaOne.merge(rightOps)

        var replicaTwo = CollaborationTextDocument(peerID: "two")
        replicaTwo.merge(bootstrap)
        replicaTwo.merge(rightOps)
        replicaTwo.merge(leftOps)

        var replicaThree = author
        replicaThree.merge(leftOps.shuffled())
        replicaThree.merge(rightOps.shuffled())

        #expect(replicaOne.text == replicaTwo.text)
        #expect(replicaTwo.text == replicaThree.text)
    }

    @Test
    func offlineSnapshotResyncConverges() {
        var peerA = CollaborationTextDocument(text: "hello", peerID: "a")
        var peerB = CollaborationTextDocument(peerID: "b")
        peerB.merge(peerA.snapshotOperations())

        _ = peerA.replace(range: 5..<5, with: " from A")
        _ = peerB.replace(range: 0..<0, with: "B says ")

        peerA.merge(peerB.snapshotOperations())
        peerB.merge(peerA.snapshotOperations())

        #expect(peerA.text == peerB.text)
        #expect(peerA.text.contains("from A"))
        #expect(peerA.text.contains("B says"))
    }
}
