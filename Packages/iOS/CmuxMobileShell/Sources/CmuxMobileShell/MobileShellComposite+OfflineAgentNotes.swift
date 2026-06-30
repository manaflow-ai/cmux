public import Foundation
import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    // MARK: - Offline agent notes

    func loadOfflineAgentNotes() {
        guard let offlineAgentNoteQueue, !isLoadingOfflineAgentNotes else { return }
        isLoadingOfflineAgentNotes = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await offlineAgentNoteQueue.loadNotes()
            let loadedIDs = Set(loaded.map(\.id))
            let locallyQueued = self.offlineAgentNotes.filter { !loadedIDs.contains($0.id) }
            self.offlineAgentNotes = loaded + locallyQueued
            self.isLoadingOfflineAgentNotes = false
            self.scheduleOfflineAgentNoteDrain()
        }
    }

    func persistOfflineAgentNotes() {
        guard let offlineAgentNoteQueue else { return }
        let snapshot = offlineAgentNotes
        Task { await offlineAgentNoteQueue.saveNotes(snapshot) }
    }

    @discardableResult
    func enqueueOfflineAgentNote(
        text: String,
        workspaceID: MobileWorkspacePreview.ID?,
        terminalID: MobileTerminalPreview.ID?
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let now = runtime?.now() ?? Date()
        let note = OfflineAgentNote(
            text: text,
            workspaceID: workspaceID?.rawValue,
            terminalID: terminalID?.rawValue,
            createdAt: now,
            updatedAt: now
        )
        offlineAgentNotes.append(note)
        persistOfflineAgentNotes()
        await reconcileComposerDraftAfterSend(sentText: text, submittedTerminalID: terminalID)
        analytics.capture("ios_offline_agent_note_queued", [
            "has_target_terminal": .bool(terminalID != nil),
        ])
        return true
    }

    public func retryOfflineAgentNotes() async {
        for index in offlineAgentNotes.indices where offlineAgentNotes[index].status == .failed {
            offlineAgentNotes[index].status = .pending
            offlineAgentNotes[index].lastError = nil
            offlineAgentNotes[index].updatedAt = runtime?.now() ?? Date()
        }
        persistOfflineAgentNotes()
        await drainOfflineAgentNotes()
    }

    public func deleteOfflineAgentNote(id: OfflineAgentNote.ID) async {
        offlineAgentNotes.removeAll { $0.id == id }
        persistOfflineAgentNotes()
    }

    public func clearSentOfflineAgentNotes() async {
        offlineAgentNotes.removeAll { $0.status == .sent }
        persistOfflineAgentNotes()
    }

    func scheduleOfflineAgentNoteDrain() {
        guard connectionState == .connected,
              remoteClient != nil,
              offlineAgentNotes.contains(where: { $0.status == .pending || $0.status == .failed }) else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.drainOfflineAgentNotes()
        }
    }

    private func drainOfflineAgentNotes() async {
        guard !isDrainingOfflineAgentNotes,
              connectionState == .connected,
              remoteClient != nil else {
            return
        }
        isDrainingOfflineAgentNotes = true
        defer { isDrainingOfflineAgentNotes = false }

        for noteID in offlineAgentNotes
            .filter({ $0.status == .pending || $0.status == .failed })
            .map(\.id) {
            guard connectionState == .connected, remoteClient != nil else { break }
            guard let index = offlineAgentNotes.firstIndex(where: { $0.id == noteID }) else { continue }
            let note = offlineAgentNotes[index]
            guard let target = offlineAgentNoteTarget(for: note) else {
                markOfflineAgentNote(
                    id: noteID,
                    status: .failed,
                    lastError: "No terminal is available for this note."
                )
                continue
            }
            markOfflineAgentNote(id: noteID, status: .sending, lastError: nil)
            let sent = await sendRemoteTerminalPaste(
                note.text,
                submitKey: "return",
                workspaceID: target.workspaceID,
                terminalID: target.terminalID
            )
            if sent {
                markOfflineAgentNote(id: noteID, status: .sent, lastError: nil, sentAt: runtime?.now() ?? Date())
                analytics.capture("ios_offline_agent_note_sent", [:])
            } else {
                markOfflineAgentNote(
                    id: noteID,
                    status: .failed,
                    lastError: "The Mac did not accept this note. Retry when the connection is stable."
                )
                analytics.capture("ios_offline_agent_note_failed", [:])
            }
        }
    }

    private func markOfflineAgentNote(
        id: OfflineAgentNote.ID,
        status: OfflineAgentNote.Status,
        lastError: String?,
        sentAt: Date? = nil
    ) {
        guard let index = offlineAgentNotes.firstIndex(where: { $0.id == id }) else { return }
        offlineAgentNotes[index].status = status
        offlineAgentNotes[index].lastError = lastError
        offlineAgentNotes[index].sentAt = sentAt ?? offlineAgentNotes[index].sentAt
        offlineAgentNotes[index].updatedAt = runtime?.now() ?? Date()
        persistOfflineAgentNotes()
    }

    private func offlineAgentNoteTarget(
        for note: OfflineAgentNote
    ) -> (workspaceID: MobileWorkspacePreview.ID, terminalID: MobileTerminalPreview.ID)? {
        if let workspaceID = note.workspaceID,
           let terminalID = note.terminalID,
           workspaces.contains(where: { workspace in
               workspace.id.rawValue == workspaceID
                   && workspace.terminals.contains(where: { $0.id.rawValue == terminalID })
           }) {
            return (
                MobileWorkspacePreview.ID(rawValue: workspaceID),
                MobileTerminalPreview.ID(rawValue: terminalID)
            )
        }
        guard let workspace = selectedWorkspace,
              let terminal = selectedTerminalID.flatMap({ terminalID in
                  workspace.terminals.first { $0.id == terminalID }
              }) ?? workspace.terminals.first(where: { $0.isReady && $0.isFocused })
                  ?? workspace.terminals.first(where: { $0.isReady })
                  ?? workspace.terminals.first else {
            return nil
        }
        return (workspace.id, terminal.id)
    }
}
