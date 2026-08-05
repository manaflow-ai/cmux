import Foundation

@MainActor
final class TerminalPanelTextBoxDraftCache {
    private var text = ""
    private var attachmentIDs: [UUID] = []
    private var isActive = false
    private var snapshot: SessionTextBoxInputDraftSnapshot?

    func updateText(_ nextText: String) {
        guard nextText != text else { return }
        text = nextText
        updateTextPart()
    }

    func updateAttachments(_ attachments: [TextBoxAttachment]) {
        let nextIDs = attachments.map(\.id)
        guard nextIDs != attachmentIDs else { return }
        attachmentIDs = nextIDs
        rebuildSnapshot(attachments: attachments)
    }

    func updateIsActive(_ nextIsActive: Bool) {
        guard nextIsActive != isActive else { return }
        isActive = nextIsActive
        snapshot?.isActive = nextIsActive
    }

    func recordExactSnapshot(_ nextSnapshot: SessionTextBoxInputDraftSnapshot?) {
        snapshot = nextSnapshot
    }

    func currentSnapshot() -> SessionTextBoxInputDraftSnapshot? {
        snapshot
    }

    private func updateTextPart() {
        guard snapshot != nil else {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshot = SessionTextBoxInputDraftSnapshot(
                    isActive: isActive,
                    parts: [.text(text)]
                )
            }
            return
        }

        if text.isEmpty {
            if snapshot?.parts.first?.kind == .text {
                snapshot?.parts.removeFirst()
            }
        } else if snapshot?.parts.first?.kind == .text {
            snapshot?.parts[0] = .text(text)
        } else {
            snapshot?.parts.insert(.text(text), at: 0)
        }

        if snapshot?.parts.contains(where: isMeaningfulTextBoxDraftPart) != true {
            snapshot = nil
        }
    }

    private func rebuildSnapshot(attachments: [TextBoxAttachment]) {
        var parts: [SessionTextBoxInputDraftPart] = []
        parts.reserveCapacity(attachments.count + (text.isEmpty ? 0 : 1))
        if !text.isEmpty {
            parts.append(.text(text))
        }
        parts.append(contentsOf: attachments.map {
            .attachment(SessionTextBoxInputAttachmentSnapshot($0))
        })
        guard parts.contains(where: isMeaningfulTextBoxDraftPart) else {
            snapshot = nil
            return
        }
        snapshot = SessionTextBoxInputDraftSnapshot(isActive: isActive, parts: parts)
    }
}

private func isMeaningfulTextBoxDraftPart(_ part: SessionTextBoxInputDraftPart) -> Bool {
    switch part.kind {
    case .text:
        return part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case .attachment:
        return part.attachment != nil
    }
}
