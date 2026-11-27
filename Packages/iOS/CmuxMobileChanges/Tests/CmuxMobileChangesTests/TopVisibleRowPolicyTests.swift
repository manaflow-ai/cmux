import Testing

@testable import CmuxMobileChanges

@Suite struct TopVisibleRowPolicyTests {
    private let policy = TopVisibleRowPolicy(rowOrderIndex: [
        "row-0": 0,
        "row-1": 1,
        "row-2": 2,
        "row-3": 3,
    ])

    @Test
    func picksDocumentTopmostRegardlessOfCallbackOrder() {
        #expect(policy.topRow(among: ["row-2", "row-0", "row-3"]) == "row-0")
        #expect(policy.topRow(among: ["row-3", "row-2"]) == "row-2")
        #expect(policy.topRow(among: ["row-1"]) == "row-1")
    }

    @Test
    func unknownIDsDoNotOverrideKnownRows() {
        #expect(policy.topRow(among: ["ghost", "row-3"]) == "row-3")
        #expect(policy.topRow(among: ["ghost-b", "ghost-a"]) == nil)
    }

    @Test
    func emptyVisibleSetResolvesToNil() {
        #expect(policy.topRow(among: []) == nil)
    }

    @Test
    func presentationIndexesRowsInDocumentOrder() async {
        let diff = """
        @@ -1,2 +1,3 @@
         let stable = true
        +let added = 1
         let tail = false
        """
        let document = UnifiedDiffParser().parse(diff)
        let presentation = await FileDiffPresentation.prepareOffMain(
            document: document,
            fileKind: .modified
        )
        let orderedByIndex = presentation.rows
            .map(\.id)
            .enumerated()
            .allSatisfy { presentation.rowOrderIndex[$0.element] == $0.offset }
        #expect(orderedByIndex)
        #expect(presentation.rowOrderIndex.count == presentation.rows.count)
    }
}
