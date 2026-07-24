import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

extension WorkspaceShellView {
    #if os(iOS)
    var submitTaskComposerFromShell: @MainActor (
        String,
        MobileWorkspaceCreateSpec,
        @escaping @MainActor () -> Void
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let store = store
        return { macDeviceID, spec, composerWillStartCreate in
            pendingCompactCreateNavigationWorkspaceIDs = nil
            var existingWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
            let result = await store.submitTaskComposer(
                macDeviceID: macDeviceID,
                spec: spec,
                willStartCreate: {
                    composerWillStartCreate()
                    guard usesCompactStack else { return }
                    let targetWorkspaceIDs = Set(store.workspaces.map(\.id))
                    existingWorkspaceIDs = targetWorkspaceIDs
                    pendingCompactCreateNavigationWorkspaceIDs = targetWorkspaceIDs
                }
            )
            if usesCompactStack, let existingWorkspaceIDs {
                settlePendingCompactCreateNavigation(
                    result: result,
                    existingWorkspaceIDs: existingWorkspaceIDs
                )
            } else {
                pendingCompactCreateNavigationWorkspaceIDs = nil
            }
            return result
        }
    }
    #endif

    /// Workspace action closures, always present for the real store. Row and
    /// detail affordances gate themselves on each workspace's owning-Mac
    /// capability snapshot, so a secondary Mac is not hidden behind the
    /// foreground Mac's advertised capabilities.
    var renameWorkspaceClosure: ((MobileWorkspacePreview.ID, String) -> Void)? {
        let store = store
        return { id, title in
            Task { @MainActor in
                let result = await store.renameWorkspace(id: id, title: title)
                handleWorkspaceActionResult(result, action: .renameWorkspace)
            }
        }
    }

    /// One shared action path for customization sheets opened from the sidebar
    /// row or workspace title. Only fields edited from the sheet's initial
    /// snapshot are applied, so a concurrent update to an untouched field is
    /// preserved. The Mac protocol applies one field per request, so this
    /// refreshes between requests and rebases the sheet after any partial success
    /// or conflict.
    var customizeWorkspaceClosure: WorkspaceCustomizationAction? {
        let store = store
        return { id, initialDraft, submittedDraft in
            guard !Task.isCancelled else { return .failure() }
            guard let workspace = store.workspaces.first(where: { $0.id == id }) else {
                return .failure(failure: WorkspaceCustomizationSaveFailure(
                    title: Self.workspaceActionFailureTitle(action: .updateWorkspaceDescription),
                    message: L10n.string(
                        "mobile.workspace.customize.workspaceUnavailable",
                        defaultValue: "This workspace is no longer available. Reopen the workspace list and try again."
                    )
                ))
            }
            let current = WorkspaceCustomizationDraft(workspace: workspace)
            var landedDraft = current
            var attemptedMutation = false

            @MainActor func refreshAfterAttemptIfNeeded() async {
                if attemptedMutation {
                    await store.refreshAfterWorkspaceMutation(id: id)
                    attemptedMutation = false
                }
            }

            @MainActor func failureResult(
                failure: WorkspaceCustomizationSaveFailure? = nil
            ) async -> WorkspaceCustomizationSaveResult {
                await refreshAfterAttemptIfNeeded()
                let refreshedDraft = store.workspaces
                    .first(where: { $0.id == id })
                    .map(WorkspaceCustomizationDraft.init(workspace:)) ?? landedDraft
                let authoritativeDraft = landedDraft.rebasingUntouchedFields(
                    from: refreshedDraft,
                    comparedTo: initialDraft
                )
                return .failure(
                    rebasedTo: authoritativeDraft == initialDraft ? nil : authoritativeDraft,
                    failure: failure
                )
            }

            @MainActor func saveFailure(
                from result: Result<Void, MobileWorkspaceMutationFailure>,
                action: WorkspaceActionToastAction
            ) -> WorkspaceCustomizationSaveFailure? {
                guard case let .failure(failure) = result else { return nil }
                return WorkspaceCustomizationSaveFailure(
                    title: Self.workspaceActionFailureTitle(action: action),
                    message: Self.workspaceActionFailureReasonText(failure)
                )
            }

            @MainActor func latestDraftAfterRefreshing() async -> WorkspaceCustomizationDraft? {
                await refreshAfterAttemptIfNeeded()
                guard let workspace = store.workspaces.first(where: { $0.id == id }) else {
                    return nil
                }
                let draft = WorkspaceCustomizationDraft(workspace: workspace)
                landedDraft = draft
                return draft
            }

            @MainActor func unavailableFailure() async -> WorkspaceCustomizationSaveResult {
                await failureResult(failure: WorkspaceCustomizationSaveFailure(
                    title: Self.workspaceActionFailureTitle(action: .updateWorkspaceDescription),
                    message: L10n.string(
                        "mobile.workspace.customize.workspaceUnavailable",
                        defaultValue: "This workspace is no longer available. Reopen the workspace list and try again."
                    )
                ))
            }

            @MainActor func conflictFailure(
                action: WorkspaceActionToastAction,
                authoritativeDraft: WorkspaceCustomizationDraft
            ) -> WorkspaceCustomizationSaveResult {
                let rebasedDraft = landedDraft.rebasingUntouchedFields(
                    from: authoritativeDraft,
                    comparedTo: initialDraft
                )
                return .failure(
                    rebasedTo: rebasedDraft == initialDraft ? nil : rebasedDraft,
                    failure: WorkspaceCustomizationSaveFailure(
                        title: Self.workspaceActionFailureTitle(action: action),
                        message: L10n.string(
                            "mobile.workspace.customize.concurrentChange",
                            defaultValue: "This workspace changed on your Mac. Review the latest values and save again."
                        )
                    )
                )
            }

            @MainActor func mutationDecision<Value: Equatable>(
                field: KeyPath<WorkspaceCustomizationDraft, Value>,
                action: WorkspaceActionToastAction
            ) async -> (
                decision: WorkspaceCustomizationFieldMutationDecision,
                authoritativeDraft: WorkspaceCustomizationDraft?,
                failure: WorkspaceCustomizationSaveResult?
            ) {
                guard initialDraft[keyPath: field] != submittedDraft[keyPath: field] else {
                    return (.none, nil, nil)
                }
                guard let authoritativeDraft = await latestDraftAfterRefreshing() else {
                    return (.none, nil, await unavailableFailure())
                }
                let decision = initialDraft.mutationDecision(
                    submitted: submittedDraft,
                    authoritative: authoritativeDraft,
                    field: field
                )
                guard decision != .conflict else {
                    return (
                        .conflict,
                        authoritativeDraft,
                        conflictFailure(
                            action: action,
                            authoritativeDraft: authoritativeDraft
                        )
                    )
                }
                return (decision, authoritativeDraft, nil)
            }

            let nameDecision = await mutationDecision(
                field: \.name,
                action: .renameWorkspace
            )
            if let failure = nameDecision.failure { return failure }
            if nameDecision.decision == .apply {
                attemptedMutation = true
                let result = await store.renameWorkspace(
                    id: id,
                    title: submittedDraft.name,
                    refreshAfterMutation: false
                )
                guard case .success = result, !Task.isCancelled else {
                    return await failureResult(failure: saveFailure(
                        from: result,
                        action: .renameWorkspace
                    ))
                }
                landedDraft = WorkspaceCustomizationDraft(
                    name: submittedDraft.name,
                    customDescription: landedDraft.customDescription,
                    customDescriptionIsTruncated: landedDraft.customDescriptionIsTruncated,
                    customColorHex: landedDraft.customColorHex,
                    isPinned: landedDraft.isPinned
                )
            }

            let descriptionDecision = await mutationDecision(
                field: \.customDescription,
                action: .updateWorkspaceDescription
            )
            if let failure = descriptionDecision.failure { return failure }
            if descriptionDecision.decision == .apply {
                if descriptionDecision.authoritativeDraft?.customDescriptionIsTruncated == true {
                    return await failureResult(failure: WorkspaceCustomizationSaveFailure(
                        title: Self.workspaceActionFailureTitle(action: .updateWorkspaceDescription),
                        message: L10n.string(
                            "mobile.workspace.customize.description.truncated",
                            defaultValue: "This Mac description is longer than iPhone can edit. Change it on Mac to avoid losing text."
                        )
                    ))
                }
                attemptedMutation = true
                let result = await store.setWorkspaceDescription(
                    id: id,
                    submittedDraft.customDescription,
                    refreshAfterMutation: false
                )
                guard case .success = result, !Task.isCancelled else {
                    return await failureResult(failure: saveFailure(
                        from: result,
                        action: .updateWorkspaceDescription
                    ))
                }
                landedDraft = WorkspaceCustomizationDraft(
                    name: landedDraft.name,
                    customDescription: submittedDraft.customDescription,
                    customDescriptionIsTruncated: false,
                    customColorHex: landedDraft.customColorHex,
                    isPinned: landedDraft.isPinned
                )
            }

            let colorDecision = await mutationDecision(
                field: \.customColorHex,
                action: .updateWorkspaceColor
            )
            if let failure = colorDecision.failure { return failure }
            if colorDecision.decision == .apply {
                attemptedMutation = true
                let result = await store.setWorkspaceColor(
                    id: id,
                    submittedDraft.customColorHex,
                    refreshAfterMutation: false
                )
                guard case .success = result, !Task.isCancelled else {
                    return await failureResult(failure: saveFailure(
                        from: result,
                        action: .updateWorkspaceColor
                    ))
                }
                landedDraft = WorkspaceCustomizationDraft(
                    name: landedDraft.name,
                    customDescription: landedDraft.customDescription,
                    customDescriptionIsTruncated: landedDraft.customDescriptionIsTruncated,
                    customColorHex: submittedDraft.customColorHex,
                    isPinned: landedDraft.isPinned
                )
            }

            let pinAction: WorkspaceActionToastAction = submittedDraft.isPinned
                ? .pinWorkspace
                : .unpinWorkspace
            let pinDecision = await mutationDecision(
                field: \.isPinned,
                action: pinAction
            )
            if let failure = pinDecision.failure { return failure }
            if pinDecision.decision == .apply {
                attemptedMutation = true
                let result = await store.setWorkspacePinned(
                    id: id,
                    submittedDraft.isPinned,
                    refreshAfterMutation: false
                )
                guard case .success = result, !Task.isCancelled else {
                    return await failureResult(failure: saveFailure(
                        from: result,
                        action: pinAction
                    ))
                }
                landedDraft = WorkspaceCustomizationDraft(
                    name: landedDraft.name,
                    customDescription: landedDraft.customDescription,
                    customDescriptionIsTruncated: landedDraft.customDescriptionIsTruncated,
                    customColorHex: landedDraft.customColorHex,
                    isPinned: submittedDraft.isPinned
                )
            }
            await refreshAfterAttemptIfNeeded()
            return Task.isCancelled ? await failureResult() : .success
        }
    }

    var setWorkspacePinnedClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, pinned in
            Task { @MainActor in
                let result = await store.setWorkspacePinned(id: id, pinned)
                handleWorkspaceActionResult(
                    result,
                    action: pinned ? .pinWorkspace : .unpinWorkspace
                )
            }
        }
    }

    var setWorkspaceUnreadClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, unread in
            Task { @MainActor in
                let result = await store.setWorkspaceUnread(id: id, unread)
                handleWorkspaceActionResult(
                    result,
                    action: unread ? .markWorkspaceUnread : .markWorkspaceRead
                )
            }
        }
    }

    var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        let store = store
        return { id in
            Task { @MainActor in
                let result = await store.closeWorkspace(id: id)
                handleWorkspaceActionResult(result, action: .closeWorkspace)
            }
        }
    }

    var moveWorkspaceClosure: ((
        _ id: MobileWorkspacePreview.ID,
        _ groupID: MobileWorkspaceGroupPreview.ID?,
        _ beforeWorkspaceID: MobileWorkspacePreview.ID?,
        _ movesGroup: Bool
    ) async -> Bool)? {
        let store = store
        return { id, groupID, beforeWorkspaceID, movesGroup in
            let result = await store.moveWorkspace(
                id: id,
                toGroup: groupID,
                before: beforeWorkspaceID,
                movesGroup: movesGroup
            )
            await MainActor.run {
                handleWorkspaceActionResult(result, action: .moveWorkspace)
            }
            if case .success = result {
                return true
            }
            return false
        }
    }

    var renameWorkspaceGroupClosure: ((MobileWorkspaceGroupPreview.ID, String) -> Void)? {
        let store = store
        return { id, title in
            Task { @MainActor in
                let result = await store.renameWorkspaceGroup(id: id, title: title)
                handleWorkspaceActionResult(result, action: .renameGroup)
            }
        }
    }

    var setWorkspaceGroupPinnedClosure: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? {
        let store = store
        return { id, pinned in
            Task { @MainActor in
                let result = await store.setWorkspaceGroupPinned(id: id, pinned)
                handleWorkspaceActionResult(
                    result,
                    action: pinned ? .pinGroup : .unpinGroup
                )
            }
        }
    }

    var ungroupWorkspaceGroupClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        let store = store
        return { id in
            Task { @MainActor in
                let result = await store.ungroupWorkspaceGroup(id: id)
                handleWorkspaceActionResult(result, action: .ungroupGroup)
            }
        }
    }

    var deleteWorkspaceGroupClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        let store = store
        return { id in
            Task { @MainActor in
                let result = await store.deleteWorkspaceGroup(id: id)
                handleWorkspaceActionResult(result, action: .deleteGroup)
            }
        }
    }

    /// Group collapse/expand closure. Present when the Mac advertises
    /// `workspace.groups.v1` or has actually emitted group sections.
    var toggleGroupCollapsedClosure: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? {
        guard store.supportsWorkspaceGroups || !store.workspaceGroups.isEmpty else { return nil }
        let store = store
        return { id, collapsed in Task { await store.setWorkspaceGroupCollapsed(id: id, collapsed) } }
    }

    var createWorkspaceInGroupInCompactStackClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard store.supportsWorkspaceCreateInGroup else { return nil }
        return { groupID in createWorkspaceInCompactStack(inGroup: groupID) }
    }

    var createWorkspaceInGroupIfConnectedClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard store.supportsWorkspaceCreateInGroup else { return nil }
        return { groupID in createWorkspaceIfConnected(inGroup: groupID) }
    }

    var createWorkspaceGroupInCompactStackClosure: (() -> Void)? {
        guard store.supportsWorkspaceGroupCreate else { return nil }
        return { createWorkspaceGroupIfConnected() }
    }

    var createWorkspaceGroupIfConnectedClosure: (() -> Void)? {
        guard store.supportsWorkspaceGroupCreate else { return nil }
        return { createWorkspaceGroupIfConnected() }
    }

    func createWorkspaceInCompactStack() {
        createWorkspaceInCompactStack(inGroup: nil)
    }

    func createWorkspaceInCompactStack(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        if store.usesLocalWorkspaceCreationFallback {
            store.createWorkspace(inGroup: groupID)
            settlePendingCompactCreateNavigation(
                result: .success(()),
                existingWorkspaceIDs: existingWorkspaceIDs
            )
            return
        }
        Task { @MainActor in
            let result = await store.createWorkspaceRequest(inGroup: groupID)
            handleWorkspaceActionResult(
                result,
                action: groupID == nil ? .createWorkspace : .createWorkspaceInGroup
            )
            settlePendingCompactCreateNavigation(
                result: result,
                existingWorkspaceIDs: existingWorkspaceIDs
            )
        }
    }

    func createWorkspaceIfConnected() {
        createWorkspaceIfConnected(inGroup: nil)
    }

    func createWorkspaceIfConnected(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        if store.usesLocalWorkspaceCreationFallback {
            store.createWorkspace(inGroup: groupID)
            return
        }
        Task { @MainActor in
            let result = await store.createWorkspaceRequest(inGroup: groupID)
            handleWorkspaceActionResult(
                result,
                action: groupID == nil ? .createWorkspace : .createWorkspaceInGroup
            )
        }
    }

    func createWorkspaceGroupIfConnected() {
        guard canCreateWorkspaceForMacSelection else { return }
        Task { @MainActor in
            let result = await store.createWorkspaceGroup()
            handleWorkspaceActionResult(result, action: .createWorkspaceGroup)
        }
    }

    func settlePendingCompactCreateNavigation(
        result: Result<Void, MobileWorkspaceMutationFailure>,
        existingWorkspaceIDs: Set<MobileWorkspacePreview.ID>
    ) {
        let succeeded = if case .success = result { true } else { false }
        if let createdPath = compactNavigationPolicy.pathForCompletedCreate(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs,
            succeeded: succeeded
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        } else {
            pendingCompactCreateNavigationWorkspaceIDs = nil
        }
    }
}
