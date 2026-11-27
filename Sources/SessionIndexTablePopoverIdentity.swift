enum SessionIndexTablePopoverIdentity: Hashable {
    case section(SectionKey)
    case transcript(section: SectionKey, entry: SessionEntry.ID)

    var sectionKey: SectionKey {
        switch self {
        case .section(let key), .transcript(let key, _):
            return key
        }
    }
}
