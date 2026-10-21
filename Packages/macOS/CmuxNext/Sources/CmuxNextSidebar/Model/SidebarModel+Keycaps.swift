import CmuxNextDesign

extension SidebarModel {
    /// The session tree's keycaps (`sidebar.sessionTree`): the digit whose Command-digit goes to
    /// each workspace row, as Command-1…9 go (`SidebarItemOrder.number(for:_:)`).
    func workspaceKeycaps(_ settings: SidebarNavigationSettings) -> [WorkspaceID: Int] {
        let order = itemOrder
        var keycaps: [WorkspaceID: Int] = [:]
        for item in order.items(settings.numbering).prefix(9) {
            guard case let .workspace(id) = item, let number = order.number(for: item, settings) else { continue }
            keycaps[id] = number
        }
        if case let .workspace(id)? = order.items(settings.numbering).last, let number = order.number(for: .workspace(id), settings) {
            keycaps[id] = number // Command-9 goes to the last item
        }
        return keycaps
    }
}
