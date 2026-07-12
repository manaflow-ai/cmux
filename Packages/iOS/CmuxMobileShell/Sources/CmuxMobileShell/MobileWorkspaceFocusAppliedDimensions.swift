struct MobileWorkspaceFocusAppliedDimensions: Equatable, Sendable {
    var pane: Bool
    var terminal: Bool

    static let all = Self(pane: true, terminal: true)
    var isEmpty: Bool { !pane && !terminal }
}
