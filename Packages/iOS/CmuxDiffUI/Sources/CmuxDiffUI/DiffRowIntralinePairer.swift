struct DiffRowIntralinePairer: Sendable {
    private let differ = IntralineDiffer()

    func apply(to input: [DiffRowSnapshot]) -> [DiffRowSnapshot] {
        var rows = input
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .deletion else {
                index += 1
                continue
            }
            let deletionStart = index
            while index < rows.count, rows[index].kind == .deletion { index += 1 }
            let additionStart = index
            while index < rows.count, rows[index].kind == .addition { index += 1 }
            let deletionCount = additionStart - deletionStart
            let additionCount = index - additionStart
            for offset in 0..<min(deletionCount, additionCount) {
                let oldIndex = deletionStart + offset
                let newIndex = additionStart + offset
                let ranges = differ.changedRanges(old: rows[oldIndex].text, new: rows[newIndex].text)
                rows[oldIndex] = rows[oldIndex].withIntralineSpans(
                    differ.spans(text: rows[oldIndex].text, emphasizedRange: ranges.old)
                )
                rows[newIndex] = rows[newIndex].withIntralineSpans(
                    differ.spans(text: rows[newIndex].text, emphasizedRange: ranges.new)
                )
            }
        }
        return rows
    }
}
