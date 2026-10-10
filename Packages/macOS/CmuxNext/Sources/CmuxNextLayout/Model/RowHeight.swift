/// One row's height in permille, as `set-row-heights` names it.
public nonisolated struct RowHeight: Hashable, Sendable {
    public var row: RowID
    public var height: Int

    public init(row: RowID, height: Int) {
        self.row = row
        self.height = height
    }
}
