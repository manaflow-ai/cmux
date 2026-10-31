import Testing

@MainActor
struct TabCellTitleTruncationTests {
    @Test func tabChipTitlesTruncateInTheMiddle() {
        let cell = TabCell(item: TabItem(id: TabID("helper-1"), title: "Helper 1"))

        #expect(cell.titleLayer.truncation == .middle)
    }
}
