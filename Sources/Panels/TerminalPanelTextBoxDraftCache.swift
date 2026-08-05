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

        let currentParts = snapshot?.parts ?? []
        let updatedParts = Self.partsByApplyingTextEdit(
            to: currentParts,
            nextText: text
        )
        if !updatedParts.contains(where: isMeaningfulTextBoxDraftPart) {
            snapshot = nil
        } else {
            snapshot = SessionTextBoxInputDraftSnapshot(
                isActive: isActive,
                parts: updatedParts
            )
        }
    }

    private struct AttachmentAnchor {
        let part: SessionTextBoxInputDraftPart
        let textOffset: Int
    }

    private struct FlatTextEdit {
        let replacedRange: Range<Int>
        let replacement: [Character]
    }

    private static func partsByApplyingTextEdit(
        to parts: [SessionTextBoxInputDraftPart],
        nextText: String
    ) -> [SessionTextBoxInputDraftPart] {
        var previousCharacters: [Character] = []
        var attachmentAnchors: [AttachmentAnchor] = []
        for part in parts {
            switch part.kind {
            case .text:
                previousCharacters.append(contentsOf: part.text ?? "")
            case .attachment:
                attachmentAnchors.append(AttachmentAnchor(
                    part: part,
                    textOffset: previousCharacters.count
                ))
            }
        }

        let nextCharacters = Array(nextText)
        guard previousCharacters != nextCharacters else { return parts }
        guard !attachmentAnchors.isEmpty else {
            return nextCharacters.isEmpty ? [] : [.text(nextText)]
        }

        let edit = minimalTextEdit(from: previousCharacters, to: nextCharacters)
        var updatedParts: [SessionTextBoxInputDraftPart] = []
        updatedParts.reserveCapacity(attachmentAnchors.count * 2 + 1)
        var emittedTextOffset = 0
        for anchor in attachmentAnchors {
            let mappedOffset = min(
                max(mappedTextOffset(anchor.textOffset, through: edit), emittedTextOffset),
                nextCharacters.count
            )
            if emittedTextOffset < mappedOffset {
                updatedParts.append(.text(String(nextCharacters[emittedTextOffset..<mappedOffset])))
            }
            updatedParts.append(anchor.part)
            emittedTextOffset = mappedOffset
        }
        if emittedTextOffset < nextCharacters.count {
            updatedParts.append(.text(String(nextCharacters[emittedTextOffset...])))
        }
        return updatedParts
    }

    private static func minimalTextEdit(
        from previous: [Character],
        to next: [Character]
    ) -> FlatTextEdit {
        let sharedLimit = min(previous.count, next.count)
        var sharedPrefixCount = 0
        while sharedPrefixCount < sharedLimit,
              previous[sharedPrefixCount] == next[sharedPrefixCount] {
            sharedPrefixCount += 1
        }

        var sharedSuffixCount = 0
        while sharedSuffixCount < previous.count - sharedPrefixCount,
              sharedSuffixCount < next.count - sharedPrefixCount,
              previous[previous.count - sharedSuffixCount - 1]
                == next[next.count - sharedSuffixCount - 1] {
            sharedSuffixCount += 1
        }

        return FlatTextEdit(
            replacedRange: sharedPrefixCount..<(previous.count - sharedSuffixCount),
            replacement: Array(next[sharedPrefixCount..<(next.count - sharedSuffixCount)])
        )
    }

    private static func mappedTextOffset(_ offset: Int, through edit: FlatTextEdit) -> Int {
        if edit.replacedRange.isEmpty {
            return offset < edit.replacedRange.lowerBound
                ? offset
                : offset + edit.replacement.count
        }
        if offset <= edit.replacedRange.lowerBound {
            return offset
        }
        if offset >= edit.replacedRange.upperBound {
            return offset + edit.replacement.count - edit.replacedRange.count
        }
        return edit.replacedRange.lowerBound + edit.replacement.count
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
