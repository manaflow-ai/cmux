import Foundation

struct NewWorkspaceMenuModel: Equatable {
    enum CreateRow: Equatable {
        case action(CmuxResolvedConfigMenuAction, deletable: Bool, isDefault: Bool)
        case separator
    }

    struct LayoutRow: Equatable {
        let menuAction: CmuxResolvedConfigMenuAction
        let isDefault: Bool
        let deletable: Bool
    }

    struct ManagementSection: Equatable {
        let defaultLayout: NewWorkspaceDefaultLayoutMenuModel
        let deletableActions: [CmuxResolvedConfigAction]
    }

    enum Section: Equatable {
        case create([CreateRow])
        case cloud
        case layouts([LayoutRow])
        case templates([String])
        case management(ManagementSection)
    }

    let sections: [Section]

    static func build(
        newWorkspaceContextMenuItems: [CmuxResolvedConfigContextMenuItem],
        agentChatAction: CmuxResolvedConfigAction?,
        cloudSectionEnabled: Bool,
        templateNames: [String],
        loadedActions: [CmuxResolvedConfigAction],
        newWorkspaceActionID: String?,
        deletable: (CmuxResolvedConfigAction) -> Bool,
        sectionOrder: CmuxNewWorkspaceMenuSectionOrder
    ) -> NewWorkspaceMenuModel {
        var createRows: [CreateRow] = []
        var layoutRows: [LayoutRow] = []
        var pendingCreateSeparator = false

        for item in newWorkspaceContextMenuItems {
            switch item {
            case .separator:
                if createRows.contains(where: { row in
                    if case .action = row { return true }
                    return false
                }) {
                    pendingCreateSeparator = true
                }
            case .action(let menuAction):
                if isWorkspaceLayout(menuAction.action) {
                    layoutRows.append(LayoutRow(
                        menuAction: menuAction,
                        isDefault: menuAction.action.id == newWorkspaceActionID,
                        deletable: deletable(menuAction.action)
                    ))
                } else {
                    if pendingCreateSeparator, createRows.last != .separator {
                        createRows.append(.separator)
                    }
                    createRows.append(.action(
                        menuAction,
                        deletable: deletable(menuAction.action),
                        isDefault: menuAction.action.id == newWorkspaceActionID
                    ))
                    pendingCreateSeparator = false
                }
            }
        }

        if let agentChatAction {
            createRows.append(.action(
                CmuxResolvedConfigMenuAction(
                    id: agentChatAction.id,
                    title: agentChatAction.title,
                    icon: agentChatAction.icon,
                    iconSourcePath: agentChatAction.iconSourcePath,
                    tooltip: agentChatAction.tooltip,
                    action: agentChatAction
                ),
                deletable: deletable(agentChatAction),
                isDefault: agentChatAction.id == newWorkspaceActionID
            ))
        }

        let defaultLayout = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: loadedActions,
            newWorkspaceActionID: newWorkspaceActionID
        )
        let management = ManagementSection(
            defaultLayout: defaultLayout,
            deletableActions: loadedActions
                .filter { isWorkspaceLayout($0) && deletable($0) }
                .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        )

        var sections: [Section] = []
        let createSection: Section? = createRows.isEmpty ? nil : .create(createRows)
        let cloudSection: Section? = cloudSectionEnabled ? .cloud : nil

        switch sectionOrder {
        case .customFirst:
            sections.append(contentsOf: [createSection, cloudSection].compactMap { $0 })
        case .cloudFirst:
            sections.append(contentsOf: [cloudSection, createSection].compactMap { $0 })
        }

        if !layoutRows.isEmpty {
            sections.append(.layouts(layoutRows))
        }
        if !templateNames.isEmpty {
            sections.append(.templates(templateNames))
        }
        if !sections.isEmpty || !management.deletableActions.isEmpty || management.defaultLayout.hasDefault || !management.defaultLayout.entries.isEmpty {
            sections.append(.management(management))
        }

        return NewWorkspaceMenuModel(sections: sections)
    }

    static func isWorkspaceLayout(_ action: CmuxResolvedConfigAction) -> Bool {
        action.workspaceCommandName != nil || action.action.inlineWorkspace != nil
    }
}
