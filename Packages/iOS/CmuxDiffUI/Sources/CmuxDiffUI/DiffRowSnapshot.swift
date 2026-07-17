struct DiffRowSnapshot: Identifiable, Sendable, Equatable {
    let id: String
    let kind: DiffRowKind
    let oldLine: Int?
    let newLine: Int?
    let text: String
    let hunkIndex: Int
    let intralineSpans: [IntralineSpan]

    init(
        id: String,
        kind: DiffRowKind,
        oldLine: Int?,
        newLine: Int?,
        text: String,
        hunkIndex: Int,
        intralineSpans: [IntralineSpan] = []
    ) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
        self.hunkIndex = hunkIndex
        self.intralineSpans = intralineSpans
    }

    func withIntralineSpans(_ spans: [IntralineSpan]) -> DiffRowSnapshot {
        DiffRowSnapshot(
            id: id,
            kind: kind,
            oldLine: oldLine,
            newLine: newLine,
            text: text,
            hunkIndex: hunkIndex,
            intralineSpans: spans
        )
    }
}
