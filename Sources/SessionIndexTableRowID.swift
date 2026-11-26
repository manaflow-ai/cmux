enum SessionIndexTableRowID: Hashable {
    case section(SectionKey)
    case gapBefore(SectionKey)
    case trailingGap
}
