/// Reference semantics keep one mutable line buffer per hunk. Copying a value
/// builder on every parsed row would repeatedly trigger Array copy-on-write.
final class HunkBuilder {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    private var lines: [DiffLine] = []

    init(id: Int, header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }

    func append(_ line: DiffLine) {
        lines.append(line)
    }

    func build() -> DiffHunk {
        DiffHunk(
            id: id,
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: lines
        )
    }
}
