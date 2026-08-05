import Foundation

@MainActor
final class TerminalPanelTextBoxDraftCache {
    // The AppKit editor owns attachment-side affinity. Flat SwiftUI text and
    // attachment bindings cannot reconstruct whether a boundary edit occurred
    // before or after an attachment, so an ordered editor snapshot always wins.
    // The flattened fallback covers programmatic, unmounted drafts and is never
    // updated while the editor is mounted.
    private var flattenedText = ""
    private var flattenedAttachments: [SessionTextBoxInputAttachmentSnapshot] = []
    private var isActive = false
    private var hasAuthoritativeSnapshot = false
    private var snapshot: SessionTextBoxInputDraftSnapshot?

    func updateIsActive(_ nextIsActive: Bool) {
        guard isActive != nextIsActive else { return }
        isActive = nextIsActive
        snapshot?.isActive = nextIsActive
    }

    func updateFlattenedText(_ nextText: String) {
        guard !hasAuthoritativeSnapshot, flattenedText != nextText else { return }
        flattenedText = nextText
        rebuildFlattenedSnapshot()
    }

    func updateFlattenedAttachments(_ attachments: [TextBoxAttachment]) {
        guard !hasAuthoritativeSnapshot else { return }
        let nextAttachments = attachments.map(SessionTextBoxInputAttachmentSnapshot.init)
        guard flattenedAttachments != nextAttachments else { return }
        flattenedAttachments = nextAttachments
        rebuildFlattenedSnapshot()
    }

    func recordExactSnapshot(_ nextSnapshot: SessionTextBoxInputDraftSnapshot?) {
        snapshot = nextSnapshot
        hasAuthoritativeSnapshot = nextSnapshot != nil
        flattenedText = nextSnapshot?.parts.compactMap(\.text).joined() ?? ""
        flattenedAttachments = nextSnapshot?.parts.compactMap(\.attachment) ?? []
        isActive = nextSnapshot?.isActive ?? false
    }

    func currentSnapshot() -> SessionTextBoxInputDraftSnapshot? {
        snapshot
    }

    private func rebuildFlattenedSnapshot() {
        guard !flattenedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !flattenedAttachments.isEmpty else {
            snapshot = nil
            return
        }
        var parts: [SessionTextBoxInputDraftPart] = []
        parts.reserveCapacity(flattenedAttachments.count + (flattenedText.isEmpty ? 0 : 1))
        if !flattenedText.isEmpty {
            parts.append(.text(flattenedText))
        }
        parts.append(contentsOf: flattenedAttachments.map(SessionTextBoxInputDraftPart.attachment))
        snapshot = parts.isEmpty
            ? nil
            : SessionTextBoxInputDraftSnapshot(isActive: isActive, parts: parts)
    }
}
