struct SplitDiffPairer: Sendable {
    func pair(rows: [DiffRowSnapshot]) -> [SplitDiffRow] {
        var result: [SplitDiffRow] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            switch row.kind {
            case .hunkHeader, .noNewline:
                result.append(SplitDiffRow(
                    id: "split:\(row.id)",
                    kind: .spanning,
                    old: nil,
                    new: nil,
                    spanning: row
                ))
                index += 1
            case .context:
                result.append(SplitDiffRow(
                    id: "split:\(row.id)",
                    kind: .code,
                    old: row,
                    new: row,
                    spanning: nil
                ))
                index += 1
            case .deletion, .addition:
                let start = index
                while index < rows.count,
                      rows[index].kind == .deletion || rows[index].kind == .addition {
                    index += 1
                }
                appendChangeRun(Array(rows[start..<index]), to: &result)
            }
        }
        return result
    }

    private func appendChangeRun(_ run: [DiffRowSnapshot], to result: inout [SplitDiffRow]) {
        let deletions = run.filter { $0.kind == .deletion }
        let additions = run.filter { $0.kind == .addition }
        for offset in 0..<max(deletions.count, additions.count) {
            let old = offset < deletions.count ? deletions[offset] : nil
            let new = offset < additions.count ? additions[offset] : nil
            let identity = old?.id ?? new?.id ?? "empty"
            result.append(SplitDiffRow(
                id: "split:\(identity):\(offset)",
                kind: .code,
                old: old,
                new: new,
                spanning: nil
            ))
        }
    }
}
