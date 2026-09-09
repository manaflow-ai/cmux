import Foundation

extension ClaudeHookSessionStoreFile {
    /// Move only this session's existing activity when an accepted upsert
    /// re-homes its record. Preserve another pane's destination ownership.
    mutating func reconcileActiveOwnerAfterUpsert(
        previous: ClaudeHookSessionRecord?,
        record: ClaudeHookSessionRecord
    ) {
        guard let previous else { return }
        let oldWorkspace = previous.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let newWorkspace = record.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldSurface = previous.surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSurface = record.surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldWorkspace != newWorkspace || oldSurface != newSurface else { return }

        let surfaceActivity = activeSessionsBySurface[oldSurface].flatMap {
            $0.sessionId == record.sessionId ? $0 : nil
        }
        let workspaceActivity = activeSessionsByWorkspace[oldWorkspace].flatMap {
            $0.sessionId == record.sessionId ? $0 : nil
        }
        guard let activity = surfaceActivity ?? workspaceActivity else { return }
        if oldWorkspace != newWorkspace {
            if workspaceActivity != nil {
                activeSessionsByWorkspace.removeValue(forKey: oldWorkspace)
            }
            if !newWorkspace.isEmpty, activeSessionsByWorkspace[newWorkspace] == nil {
                activeSessionsByWorkspace[newWorkspace] = activity
            }
        }
        if oldSurface != newSurface {
            if surfaceActivity != nil {
                activeSessionsBySurface.removeValue(forKey: oldSurface)
            }
            if !newSurface.isEmpty, activeSessionsBySurface[newSurface] == nil {
                activeSessionsBySurface[newSurface] = activity
            }
        }
    }
}
