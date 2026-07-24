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
        // Tracks whether any create action has been emitted yet, so a leading
        // separator is dropped. Kept as a flag rather than rescanning the
        // growing `createRows` array on every separator (avoids O(n^2) over
        // user-configurable menu items).
        var createSectionHasAction = false

        for item in newWorkspaceContextMenuItems {
            switch item {
            case .separator:
                if createSectionHasAction {
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
                    createSectionHasAction = true
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
        let layoutsSection: Section? = layoutRows.isEmpty ? nil : .layouts(layoutRows)

        // Layout rows come from `ui.newWorkspace.contextMenu`, so they belong
        // to the custom side of the `menuSectionOrder` contract: with
        // `customFirst` the whole custom block (create actions, then the
        // labeled Layouts section) stays above the built-in Cloud VM section.
        switch sectionOrder {
        case .customFirst:
            sections.append(contentsOf: [createSection, layoutsSection, cloudSection].compactMap { $0 })
        case .cloudFirst:
            sections.append(contentsOf: [cloudSection, createSection, layoutsSection].compactMap { $0 })
        }
        if !templateNames.isEmpty {
            sections.append(.templates(templateNames))
        }
        // Always present: the Save affordance must survive an otherwise-empty
        // menu (no create/cloud/layout/template rows), matching the pre-model menu.
        sections.append(.management(management))

        return NewWorkspaceMenuModel(sections: sections)
    }

    static func isWorkspaceLayout(_ action: CmuxResolvedConfigAction) -> Bool {
        action.workspaceCommandName != nil || action.action.inlineWorkspace != nil
    }
}
