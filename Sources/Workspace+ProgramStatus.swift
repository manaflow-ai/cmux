import CmuxSidebar
import Foundation

extension Workspace {
    static let programStatusKey = "program_status"

    func applyProgramStatus(_ report: ProgramStatusReport, panelId: UUID) {
        guard panels[panelId] != nil else { return }
        var store = programStatusStoresByPanelId[panelId] ?? ProgramStatusRecordStore()
        store.apply(report)
        programStatusStoresByPanelId[panelId] = store

        switch report.event {
        case .promptStart:
            setAgentLifecycle(key: Self.programStatusKey, panelId: panelId, lifecycle: .idle)
        case .report:
            switch report.state {
            case .working: setAgentLifecycle(key: Self.programStatusKey, panelId: panelId, lifecycle: .running)
            case .blocked: setAgentLifecycle(key: Self.programStatusKey, panelId: panelId, lifecycle: .needsInput)
            case .idle, .done, .error: setAgentLifecycle(key: Self.programStatusKey, panelId: panelId, lifecycle: .idle)
            case .clear:
                _ = clearAgentLifecycle(key: Self.programStatusKey, panelId: panelId)
            }
        }
        projectProgramStatus(panelId: panelId)
    }

    func dropTransientProgramStatus(panelId: UUID) {
        guard var store = programStatusStoresByPanelId[panelId] else { return }
        store.dropTransient()
        programStatusStoresByPanelId[panelId] = store
        projectProgramStatus(panelId: panelId)
    }

    func dismissCompletedProgramStatus(panelId: UUID) {
        guard var store = programStatusStoresByPanelId[panelId] else { return }
        store.dismissCompleted()
        programStatusStoresByPanelId[panelId] = store
        projectProgramStatus(panelId: panelId)
    }

    func clearProgramStatusPanel(panelId: UUID) {
        programStatusStoresByPanelId.removeValue(forKey: panelId)
        programStatusUrgencyByPanelId.removeValue(forKey: panelId)
        _ = clearAgentLifecycle(key: Self.programStatusKey, panelId: panelId)
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
        let fallback: String = switch state {
        case .blocked where record.kind == .permission:
            String(localized: "programStatus.state.needsPermission", defaultValue: "Needs permission")
        case .blocked where record.kind == .question:
            String(localized: "programStatus.state.needsAnswer", defaultValue: "Needs an answer")
        case .blocked where record.kind == .auth:
            String(localized: "programStatus.state.needsSignIn", defaultValue: "Needs sign-in")
        case .blocked:
            String(localized: "programStatus.state.needsInput", defaultValue: "Needs input")
        case .working:
            String(localized: "programStatus.state.working", defaultValue: "Working")
        case .done:
            String(localized: "programStatus.state.done", defaultValue: "Done")
        case .error:
            String(localized: "programStatus.state.failed", defaultValue: "Failed")
        case .idle, .clear:
            return
        }
        let detail = message ?? title ?? fallback
        let value = [app, detail].compactMap { $0 }.joined(separator: " · ")
        let entry = SidebarStatusEntry(
            key: Self.programStatusKey,
            value: value,
            icon: switch state {
            case .blocked: "bell.fill"
            case .working: "bolt.fill"
            case .done: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            case .idle, .clear: nil
            },
            color: state == .blocked ? "#4C8DFF" : nil,
            priority: ProgramStatusRecordStore.urgencyRank(state),
            timestamp: Date(),
            workState: state == .working || state == .blocked ? .running : nil,
            progress: record.progress.map { SidebarProgressState(value: Double($0) / 100, label: "\($0)%") }
        )
        setStatusEntry(entry, key: Self.programStatusKey, panelId: panelId)
        refreshProgramStatusWorkspaceEntry()
    }

    private func refreshProgramStatusWorkspaceEntry() {
        let entries = agentStatusEntriesByPanelId.values.compactMap { $0[Self.programStatusKey] }
        guard let entry = entries.max(by: { lhs, rhs in
            let left = lhs.priority
            let right = rhs.priority
            return left == right ? lhs.timestamp < rhs.timestamp : left < right
        }) else {
            statusEntries.removeValue(forKey: Self.programStatusKey)
            return
        }
        statusEntries[Self.programStatusKey] = entry
    }

    func sanitizedProgramStatusText(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.filter { $0.properties.generalCategory != .format }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(512))
    }
}
