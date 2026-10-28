/// `appearance.borders` in cmux.json: `default` draws the app's borders,
/// hairlines and separators; `none` removes every one of them.
public nonisolated enum BorderMode: String, Sendable, CaseIterable, Codable, TunableChoice {
    case `default`
    case none

    public var tunableTitle: String {
        switch self {
        case .default: "Default"
        case .none: "None"
        }
    }
}
