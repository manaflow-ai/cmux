struct TerminalHierarchyCloseConfirmation: Equatable {
    let row: TerminalHierarchyRowSnapshot
    let confirmed: Bool

    func action(
        _ confirm: @escaping (TerminalHierarchyCloseConfirmation) -> Void
    ) -> () -> Void {
        { confirm(self) }
    }
}
