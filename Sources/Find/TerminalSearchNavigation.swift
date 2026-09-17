enum TerminalSearchNavigation: String, CaseIterable, Sendable {
    case next
    case previous

    @discardableResult
    func perform(_ performBindingAction: (String) -> Bool) -> Bool {
        performBindingAction("navigate_search:\(rawValue)")
    }
}
