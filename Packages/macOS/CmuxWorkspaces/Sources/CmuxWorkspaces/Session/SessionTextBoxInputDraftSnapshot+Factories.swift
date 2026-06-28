public import AppKit
import CMUXAgentLaunch

public extension SessionTextBoxInputDraftSnapshot {
    /// Builds a draft snapshot from an attributed string's submission parts.
    ///
    /// `attachmentSnapshot` captures each live attachment into its persisted
    /// snapshot. It stays a host-supplied closure because the app captures the
    /// snapshot through the process-wide draft store (pasteboard-ownership check
    /// plus durable copy), which lives in the executable target.
    static func make(
        fromAttributed attributed: NSAttributedString,
        isActive: Bool,
        attachmentSnapshot: (TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot
    ) -> SessionTextBoxInputDraftSnapshot? {
        make(
            parts: attributed.textBoxSubmissionParts,
            isActive: isActive,
            attachmentSnapshot: attachmentSnapshot
        )
    }

    /// Builds a draft snapshot from a plain-text run and trailing attachments.
    ///
    /// `attachmentSnapshot` captures each live attachment into its persisted
    /// snapshot through the host draft store (see ``make(fromAttributed:isActive:attachmentSnapshot:)``).
    static func make(
        text: String,
        attachments: [TextBoxAttachment],
        isActive: Bool,
        attachmentSnapshot: (TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot
    ) -> SessionTextBoxInputDraftSnapshot? {
        var parts: [TextBoxSubmissionPart] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        parts.append(contentsOf: attachments.map { .attachment($0) })
        return make(parts: parts, isActive: isActive, attachmentSnapshot: attachmentSnapshot)
    }

    /// The concatenated plain text carried by a draft's text parts.
    static func plainText(from draft: SessionTextBoxInputDraftSnapshot) -> String {
        draft.parts.compactMap { part -> String? in
            guard part.kind == .text else { return nil }
            return part.text
        }.joined()
    }

    /// The live attachments rebuilt from a draft's attachment parts.
    static func attachments(from draft: SessionTextBoxInputDraftSnapshot) -> [TextBoxAttachment] {
        draft.parts.compactMap { part -> TextBoxAttachment? in
            guard part.kind == .attachment,
                  let attachment = part.attachment else { return nil }
            return attachment.textBoxAttachment()
        }
    }

    private static func make(
        parts: [TextBoxSubmissionPart],
        isActive: Bool,
        attachmentSnapshot: (TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot
    ) -> SessionTextBoxInputDraftSnapshot? {
        let draftParts = parts.compactMap { part -> SessionTextBoxInputDraftPart? in
            switch part {
            case .text(let text):
                guard !text.isEmpty else { return nil }
                return .text(text)
            case .attachment(let attachment):
                guard let attachment = attachment as? TextBoxAttachment else { return nil }
                return .attachment(attachmentSnapshot(attachment))
            }
        }
        let hasMeaningfulContent = draftParts.contains { part in
            switch part.kind {
            case .text:
                return part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .attachment:
                return part.attachment != nil
            }
        }
        guard hasMeaningfulContent else { return nil }
        return SessionTextBoxInputDraftSnapshot(isActive: isActive, parts: draftParts)
    }
}
