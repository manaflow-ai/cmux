public import CmuxNextDesign

extension HoverCardSettings {
    /// The workspace card's options as the sidebar reads them (`DesignSettings.workspaceHoverCard`).
    public var workspaceCardOptions: WorkspaceHoverCardOptions {
        var options = WorkspaceHoverCardOptions()
        options.layout = WorkspaceHoverCardOptions.Layout(rawValue: layout.rawValue) ?? .timeline
        options.showsTimings = showsTimings
        options.showsPrompts = showsPrompts
        options.showsWaiting = showsWaiting
        options.showsGit = showsGit
        options.showsPorts = showsPorts
        let range = WorkspaceHoverCardOptions.maxRowsRange
        options.maxRows = min(max(Int(maxRows.rounded()), range.lowerBound), range.upperBound)
        return options
    }

    /// The group cards' options as group headers and tab group chips read them
    /// (`DesignSettings.groupHoverCard`).
    public var groupCardOptions: GroupHoverCardOptions {
        var options = GroupHoverCardOptions()
        options.workspaceGroups = groupsWorkspaceGroups
        options.tabGroups = groupsTabGroups
        options.delay = .milliseconds(Int(groupsDelayMilliseconds.rounded()))
        options.order = GroupHoverCardOptions.Order(rawValue: groupsOrder.rawValue) ?? .status
        let range = GroupHoverCardOptions.maxMembersRange
        options.maxMembers = min(max(Int(groupsMaxMembers.rounded()), range.lowerBound), range.upperBound)
        let flags: [(GroupHoverCardOptions.Section, Bool)] = [
            (.status, groupsShowsStatus), (.members, groupsShowsMembers), (.activity, groupsShowsActivity),
            (.git, groupsShowsGit), (.ports, groupsShowsPorts),
        ]
        options.shown = Set(flags.filter(\.1).map(\.0))
        return options
    }
}
