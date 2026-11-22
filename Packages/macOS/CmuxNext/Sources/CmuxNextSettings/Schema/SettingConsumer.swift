/// An app that reads a cmux.json key. Raw values are the export's `consumers` names.
public nonisolated enum SettingConsumer: String, Sendable, Hashable, CaseIterable, Comparable {
    case cmuxNext = "cmux-next"
    case cmuxBrowser = "cmux-browser"

    public static func < (lhs: SettingConsumer, rhs: SettingConsumer) -> Bool { lhs.rawValue < rhs.rawValue }
}
