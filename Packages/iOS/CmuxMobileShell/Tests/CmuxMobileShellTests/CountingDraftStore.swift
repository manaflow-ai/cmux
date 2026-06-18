import Foundation
@testable import CmuxMobileShell

/// A test ``TerminalDraftStoring`` that counts `saveDraft` calls and suspends
/// the FIRST save for many scheduler turns. Drives the coalescing assertion:
/// while the first save is suspended, every further keystroke must fold into
/// one pending latest-value flush instead of queuing its own full-text
/// snapshot, so a typing burst reaches the store as a bounded number of saves.
actor CountingDraftStore: TerminalDraftStoring {
    private var drafts: [String: String] = [:]
    private var delayedFirstSave = false
    /// Number of `saveDraft` calls received.
    private(set) var saveCount = 0

    func draft(forTerminalID terminalID: String) async -> String? {
        drafts[terminalID]
    }

    func saveDraft(_ draft: String, forTerminalID terminalID: String) async {
        saveCount += 1
        if !delayedFirstSave {
            delayedFirstSave = true
            for _ in 0..<50 { await Task.yield() }
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[terminalID] = nil
        } else {
            drafts[terminalID] = draft
        }
    }

    func clearDraft(forTerminalID terminalID: String) async {
        drafts[terminalID] = nil
    }

    func clearAllDrafts() async {
        drafts.removeAll()
    }
}
