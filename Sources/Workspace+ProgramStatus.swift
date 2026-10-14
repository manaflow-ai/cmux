import CmuxSidebar
import Foundation

extension Workspace {
    static let programStatusKey = "program_status"

    /// Applies one OSC 7501 report and publishes the resulting safe snapshot.
    func applyProgramStatus(_ report: ProgramStatusReport, panelId: UUID) {
        guard panels[panelId] != nil else { return }
        // Every shell prompt emits a prompt-start event; panes that never
        // reported program status have nothing to drop. A clear has nothing to remove either.
        if report.event == .promptStart || report.state == .clear,
           programStatusStoresByPanelId[panelId] == nil { return }
        let updatedStore = updateProgramStatusStore(panelId: panelId) { $0.apply(report) }
        guard let store = updatedStore else { return }
        CmuxEventBus.shared.publishProgramStatusChanged(
            workspaceId: id,
            surfaceId: panelId,
            report: report,
            store: store
        )
    }

    /// Removes working and blocked records after prompt-idle or child exit.
    func dropTransientProgramStatus(panelId: UUID) {
        let updatedStore = updateProgramStatusStore(panelId: panelId, createIfMissing: false) { $0.dropTransient() }
        guard let store = updatedStore else { return }
        CmuxEventBus.shared.publishProgramStatusChanged(
            workspaceId: id,
            surfaceId: panelId,
            event: .transientDrop,
            store: store
        )
    }

    /// Removes done and error records after the user returns to a pane.
    func dismissCompletedProgramStatus(panelId: UUID) {
        let updatedStore = updateProgramStatusStore(panelId: panelId, createIfMissing: false) { $0.dismissCompleted() }
        guard let store = updatedStore else { return }
        CmuxEventBus.shared.publishProgramStatusChanged(
            workspaceId: id,
            surfaceId: panelId,
            event: .dismissed,
            store: store
        )
    }

    /// Mutates one pane's store and re-projects the sidebar only when the
    /// records changed. Returning the new store lets each lifecycle caller
    /// publish one matching event without duplicating no-op notifications.
    private func updateProgramStatusStore(
        panelId: UUID,
        createIfMissing: Bool = true,
        _ mutate: (inout ProgramStatusRecordStore) -> Void
    ) -> ProgramStatusRecordStore? {
        guard var store = programStatusStoresByPanelId[panelId] ?? (createIfMissing ? ProgramStatusRecordStore() : nil) else {
            return nil
        }
        let previous = programStatusStoresByPanelId[panelId]
        mutate(&store)
        guard store != previous else { return nil }
        programStatusStoresByPanelId[panelId] = store
        projectProgramStatus(panelId: panelId)
        return store
    }

    /// Adopts the records a moved terminal carried from its previous owner and
    /// publishes them under this workspace, pairing the source's `removed` event.
    func restoreProgramStatusStore(_ store: ProgramStatusRecordStore?, panelId: UUID) {
        guard let store, panels[panelId] != nil else { return }
        programStatusStoresByPanelId[panelId] = store
        projectProgramStatus(panelId: panelId)
        guard !store.records.isEmpty else { return }
        CmuxEventBus.shared.publishProgramStatusChanged(
            workspaceId: id,
            surfaceId: panelId,
            event: .adopted,
            store: store
        )
    }

    /// Drops every terminal's records for a sidebar reset. Each terminal that
    /// had records publishes an empty `clear`, matching a bare OSC 7501 clear.
    func resetProgramStatus() {
        let clearedPanelIds = programStatusStoresByPanelId
            .filter { !$0.value.records.isEmpty }
            .keys
            .sorted { $0.uuidString < $1.uuidString }
        programStatusStoresByPanelId.removeAll()
        programStatusUrgencyByPanelId.removeAll()
        for panelId in clearedPanelIds {
            CmuxEventBus.shared.publishProgramStatusChanged(
                workspaceId: id,
                surfaceId: panelId,
                event: .clear,
                store: ProgramStatusRecordStore()
            )
        }
    }

    /// Drops a closed or detached terminal's records. Consumers saw those
    /// records under this workspace, so a non-empty store publishes `removed`.
    func clearProgramStatusPanel(panelId: UUID) {
        let removedStore = programStatusStoresByPanelId.removeValue(forKey: panelId)
        programStatusUrgencyByPanelId.removeValue(forKey: panelId)
        removePanelStatusEntry(key: Self.programStatusKey, panelId: panelId)
        refreshProgramStatusWorkspaceEntry()
        guard let removedStore, !removedStore.records.isEmpty else { return }
        CmuxEventBus.shared.publishProgramStatusChanged(
            workspaceId: id,
            surfaceId: panelId,
            event: .removed,
            store: ProgramStatusRecordStore()
        )
    }

    private func projectProgramStatus(panelId: UUID) {
        guard let store = programStatusStoresByPanelId[panelId],
              let record = store.mostUrgentRecord() else {
            programStatusUrgencyByPanelId.removeValue(forKey: panelId)
            removePanelStatusEntry(key: Self.programStatusKey, panelId: panelId)
            refreshProgramStatusWorkspaceEntry()
            return
        }

        let state = record.state
        programStatusUrgencyByPanelId[panelId] = ProgramStatusRecordStore.urgencyRank(state)
        let app = store.effectiveApp(for: record)
        let message = sanitizedProgramStatusText(record.message)
        let title = sanitizedProgramStatusText(record.title)
        let fallback: String
        let icon: String
        switch state {
        case .blocked:
            icon = "bell.fill"
            switch record.kind {
            case .permission:
                fallback = String(localized: "programStatus.state.needsPermission", defaultValue: "Needs permission")
            case .question:
                fallback = String(localized: "programStatus.state.needsAnswer", defaultValue: "Needs an answer")
            case .auth:
                fallback = String(localized: "programStatus.state.needsSignIn", defaultValue: "Needs sign-in")
            case .none:
                fallback = String(localized: "programStatus.state.needsInput", defaultValue: "Needs input")
            }
        case .working:
            icon = "bolt.fill"
            fallback = String(localized: "programStatus.state.working", defaultValue: "Working")
        case .done:
            icon = "checkmark.circle.fill"
            fallback = String(localized: "programStatus.state.done", defaultValue: "Done")
        case .error:
            icon = "exclamationmark.triangle.fill"
            fallback = String(localized: "programStatus.state.failed", defaultValue: "Failed")
        case .idle, .clear:
            return
        }
        let detail = message ?? title ?? fallback
        let percent = record.progress.map { "\($0)%" }
        let value = [app, detail, percent].compactMap { $0 }.joined(separator: " · ")
        let entry = SidebarStatusEntry(
            key: Self.programStatusKey,
            value: value,
            icon: icon,
            color: state == .blocked ? "#4C8DFF" : nil,
            priority: ProgramStatusRecordStore.urgencyRank(state),
            timestamp: Date()
        )
        setStatusEntry(entry, key: Self.programStatusKey, panelId: panelId)
        refreshProgramStatusWorkspaceEntry()
    }

    private func refreshProgramStatusWorkspaceEntry() {
        let entries = agentStatusEntriesByPanelId.compactMap { panelId, entries in
            panels[panelId] == nil ? nil : entries[Self.programStatusKey]
        }
        let winner = entries.max(by: { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.timestamp < rhs.timestamp : lhs.priority < rhs.priority
        })
        guard statusEntries[Self.programStatusKey] != winner else { return }
        if let winner {
            statusEntries[Self.programStatusKey] = winner
        } else {
            statusEntries.removeValue(forKey: Self.programStatusKey)
        }
    }

    func sanitizedProgramStatusText(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.filter { $0.properties.generalCategory != .format }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(512))
    }
}
