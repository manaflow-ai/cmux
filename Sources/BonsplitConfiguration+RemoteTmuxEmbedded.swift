import Bonsplit

extension BonsplitConfiguration {
    /// Workspace-derived policy for a nested remote-tmux split tree.
    var remoteTmuxEmbedded: BonsplitConfiguration {
        var configuration = self
        configuration.allowSplits = true
        configuration.allowCloseLastPane = false
        configuration.allowTabReordering = false
        configuration.allowCrossPaneTabMove = false
        configuration.allowsTabContextMenu = false
        configuration.autoCloseEmptyPanes = false
        configuration.contentViewLifecycle = .keepAllAlive
        configuration.newTabPosition = .end
        configuration.tabBarVisibility = .always
        configuration.dividerPositionRange = 0...1

        configuration.appearance.minimumPaneWidth = 1
        configuration.appearance.minimumPaneHeight = 1
        configuration.appearance.tabBarLeadingInset = 0
        configuration.appearance.enableAnimations = false
        configuration.appearance.splitButtons = configuration.appearance.splitButtons.filter {
            switch $0.action {
            case .splitRight, .splitDown:
                return true
            default:
                return false
            }
        }.flatMap(Self.remoteTmuxEmbeddedSplitButtons)
        return configuration
    }

    /// The mirror's delegate builds no menus, so a split button keeps only its
    /// click, and its Option-click split (the compact cluster's Split Down)
    /// becomes a visible button of its own.
    static func remoteTmuxEmbeddedSplitButtons(_ button: SplitActionButton) -> [SplitActionButton] {
        var primary = button
        primary.menuBehavior = .none
        primary.alternateAction = nil
        guard let alternate = button.alternateAction, alternate != button.action,
              alternate == .splitRight || alternate == .splitDown else { return [primary] }
        primary.tooltip = nil
        var secondary = primary
        secondary.id = button.id + ".alternate"
        secondary.action = alternate
        secondary.icon = .systemImage(alternate == .splitDown ? "square.split.1x2" : "square.split.2x1")
        return [primary, secondary]
    }
}
