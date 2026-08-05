import Foundation

@MainActor
final class TerminalPanelTextBoxDraftCache {
    private var text = ""
    private var attachmentSnapshots: [SessionTextBoxInputAttachmentSnapshot] = []
    private var isActive = false
    private var snapshot: SessionTextBoxInputDraftSnapshot?

    func updateText(_ nextText: String) {
        guard nextText != text else { return }
        text = nextText
        updateTextPart()
    }

    func updateAttachments(_ attachments: [TextBoxAttachment]) {
        let nextSnapshots = attachments.map(SessionTextBoxInputAttachmentSnapshot.init)
        guard nextSnapshots != attachmentSnapshots else { return }
        attachmentSnapshots = nextSnapshots
        rebuildSnapshot(attachments: nextSnapshots)
    }

    func updateIsActive(_ nextIsActive: Bool) {
        guard nextIsActive != isActive else { return }
        isActive = nextIsActive
        snapshot?.isActive = nextIsActive
    }

    func recordExactSnapshot(_ nextSnapshot: SessionTextBoxInputDraftSnapshot?) {
        snapshot = nextSnapshot
        text = nextSnapshot?.parts.compactMap(\.text).joined() ?? ""
        attachmentSnapshots = nextSnapshot?.parts.compactMap(\.attachment) ?? []
        isActive = nextSnapshot?.isActive ?? false
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

        let textIndices = snapshot?.parts.indices.filter {
            snapshot?.parts[$0].kind == .text
        } ?? []
        if text.isEmpty {
            for index in textIndices.reversed() {
                snapshot?.parts.remove(at: index)
            }
        } else if let firstTextIndex = textIndices.first {
            snapshot?.parts[firstTextIndex] = .text(text)
            for index in textIndices.dropFirst().reversed() {
                snapshot?.parts.remove(at: index)
            }
        } else {
            snapshot?.parts.insert(.text(text), at: 0)
        }

        if snapshot?.parts.contains(where: isMeaningfulTextBoxDraftPart) != true {
            snapshot = nil
        }
    }

    private func rebuildSnapshot(
        attachments: [SessionTextBoxInputAttachmentSnapshot]
    ) {
        var remainingCountByAttachment: [SessionTextBoxInputAttachmentSnapshot: Int] = [:]
        for attachment in attachments {
            remainingCountByAttachment[attachment, default: 0] += 1
        }
        var preservedCountByAttachment: [SessionTextBoxInputAttachmentSnapshot: Int] = [:]
        var parts: [SessionTextBoxInputDraftPart] = []
        parts.reserveCapacity(attachments.count + (text.isEmpty ? 0 : 1))
        for part in snapshot?.parts ?? [] {
            switch part.kind {
            case .text:
                parts.append(part)
            case .attachment:
                guard let existing = part.attachment,
                      let remainingCount = remainingCountByAttachment[existing],
                      remainingCount > 0 else {
                    continue
                }
                parts.append(.attachment(existing))
                remainingCountByAttachment[existing] = remainingCount - 1
                preservedCountByAttachment[existing, default: 0] += 1
            }
        }
        if parts.isEmpty, !text.isEmpty {
            parts.append(.text(text))
        }
        for attachment in attachments {
            if let preservedCount = preservedCountByAttachment[attachment],
               preservedCount > 0 {
                preservedCountByAttachment[attachment] = preservedCount - 1
            } else {
                parts.append(.attachment(attachment))
            }
        }
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
