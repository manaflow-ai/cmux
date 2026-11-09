public import CmuxNextActions

extension HomeDirectory {
    /// The palette's pick for a Chief argument (``ActionSuggestions/homeChiefs``): the user's Chiefs
    /// that are not archived here, the primary first, each by its agent id under its name.
    public func chiefSuggestions() -> [ActionEnumCase] {
        let archived = archivedChiefs
        let shown = chiefs.filter { !archived.contains($0.id) }
        return (shown.filter(\.isDefault) + shown.filter { !$0.isDefault })
            .map { ActionEnumCase(value: $0.id, title: $0.name.isEmpty ? $0.id : $0.name) }
    }
}
