/// Selects the bounded set of diff pages that may own heavy view state.
struct DiffPagerMountPolicy: Sendable {
    let adjacentPageCount: Int

    init(adjacentPageCount: Int = 1) {
        precondition(adjacentPageCount >= 0)
        self.adjacentPageCount = adjacentPageCount
    }

    func shouldMount(pageIndex: Int, selectedIndex: Int) -> Bool {
        abs(pageIndex - selectedIndex) <= adjacentPageCount
    }

    func mountedIndices(selectedIndex: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let selectedIndex = min(max(selectedIndex, 0), pageCount - 1)
        let lowerBound = max(0, selectedIndex - adjacentPageCount)
        let upperBound = min(pageCount - 1, selectedIndex + adjacentPageCount)
        return Array(lowerBound...upperBound)
    }
}
