import CmuxSidebar
import Foundation

extension Workspace {
    static let programStatusKey = "program_status"

    func applyProgramStatus(_ report: ProgramStatusReport, panelId: UUID) {
        guard panels[panelId] != nil else { return }
        // Every shell prompt emits a prompt-start event; panes that never
        // reported program status have nothing to drop.
        if report.event == .promptStart, programStatusStoresByPanelId[panelId] == nil { return }
        updateProgramStatusStore(panelId: panelId) { $0.apply(report) }
    }

    func dropTransientProgramStatus(panelId: UUID) {
        updateProgramStatusStore(panelId: panelId, createIfMissing: false) { $0.dropTransient() }
    }

    func dismissCompletedProgramStatus(panelId: UUID) {
        updateProgramStatusStore(panelId: panelId, createIfMissing: false) { $0.dismissCompleted() }
    }

    /// Mutates one pane's store and re-projects the sidebar only when the
    /// records changed, so prompts and focus changes do not republish status.
    private func updateProgramStatusStore(
        panelId: UUID,
        createIfMissing: Bool = true,
        _ mutate: (inout ProgramStatusRecordStore) -> Void
    ) {
        guard var store = programStatusStoresByPanelId[panelId] ?? (createIfMissing ? ProgramStatusRecordStore() : nil) else {
            return
        }
        let previous = programStatusStoresByPanelId[panelId]
        mutate(&store)
        guard store != previous else { return }
        programStatusStoresByPanelId[panelId] = store
        projectProgramStatus(panelId: panelId)
    }

    func clearProgramStatusPanel(panelId: UUID) {
        programStatusStoresByPanelId.removeValue(forKey: panelId)
        programStatusUrgencyByPanelId.removeValue(forKey: panelId)
        removePanelStatusEntry(key: Self.programStatusKey, panelId: panelId)
        refreshProgramStatusWorkspaceEntry()
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
