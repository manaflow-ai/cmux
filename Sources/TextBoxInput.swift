import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os

enum TextBoxLayout {
    static let minLines = 1
    static let lineSpacing: CGFloat = 0
    static let textInset = NSSize(width: 1, height: 5)
    static let multilineTextInset = NSSize(width: 1, height: 4)
    static let textBaselineOffset: CGFloat = 0
    static let inlineAttachmentTextInsetCompensation: CGFloat = 3
    static let inlineAttachmentVerticalOffset: CGFloat = 4
    static let placeholderVerticalOffset: CGFloat = 0
    static let minimumTextHeight: CGFloat = 30
    static let pillCornerRadius: CGFloat = 15
    static let pillHorizontalPadding: CGFloat = 5
    static let pillVerticalPadding: CGFloat = 0
    static let iconButtonSize: CGFloat = 24
    static let iconSymbolSize: CGFloat = 13
    static let sendSymbolSize: CGFloat = 14
    static let buttonBottomPadding: CGFloat = 3
    static let leadingButtonHorizontalOffset: CGFloat = -1
    static let trailingButtonHorizontalOffset: CGFloat = 1
    static let attachmentImageSize: CGFloat = 16
    static let attachmentChipHeight: CGFloat = 18
    static let inlineAttachmentMaxTextWidth: CGFloat = 118
    static let inlineAttachmentTrailingControlWidth: CGFloat = 14

    static func textInset(forLineCount lineCount: Int) -> NSSize {
        lineCount <= minLines ? textInset : multilineTextInset
    }
}

struct TextBoxFailedSubmitRollbackSnapshot: Equatable {
    let revision: UInt64
    let text: String
    let attachmentCount: Int

    var isEmpty: Bool {
        text.isEmpty && attachmentCount == 0
    }
}

enum TextBoxFailedSubmitRollbackPolicy {
    static func shouldRestore(
        rollbackSnapshot: TextBoxFailedSubmitRollbackSnapshot,
        currentSnapshot: TextBoxFailedSubmitRollbackSnapshot
    ) -> Bool {
        currentSnapshot.revision == rollbackSnapshot.revision && currentSnapshot.isEmpty
    }
}

enum TextBoxTerminalKey: String {
    case arrowUp = "up"
    case arrowDown = "down"
    case arrowLeft = "left"
    case arrowRight = "right"
    case tab
    case backspace
    case escape
    case returnKey = "return"
}

func shouldHandleTextBoxPlainArrowLocally(
    keyCode: UInt16,
    firstResponderHasMarkedText: Bool,
    flags: NSEvent.ModifierFlags
) -> Bool {
    guard !firstResponderHasMarkedText else { return false }
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    guard normalizedFlags.isEmpty else { return false }

    switch Int(keyCode) {
    case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
        return true
    default:
        return false
    }
}

func shouldSynchronizeExternalTextToTextBox(
    inlineAttachmentCount: Int,
    plainText: String,
    externalText: String,
    hasMarkedText: Bool
) -> Bool {
    inlineAttachmentCount == 0 && !hasMarkedText && plainText != externalText
}

func shouldShowTextBoxPlaceholder(
    text: String,
    attachmentCount: Int,
    hasMarkedText: Bool
) -> Bool {
    text.isEmpty && attachmentCount == 0 && !hasMarkedText
}

func shouldEnableTextBoxSubmit(
    text: String,
    attachmentCount: Int,
    hasPendingAttachmentUpload: Bool,
    hasMarkedText: Bool
) -> Bool {
    !hasPendingAttachmentUpload
        && !hasMarkedText
        && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0)
}

func shouldSubmitTextBox(
    hasPendingAttachmentUpload: Bool,
    hasMarkedText: Bool
) -> Bool {
    !hasPendingAttachmentUpload && !hasMarkedText
}

func textBoxCommandShortcutKey(
    for event: NSEvent,
    translateKey: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:),
    normalizedCharacters: (NSEvent) -> String = KeyboardLayout.normalizedCharacters(for:)
) -> String {
    if let translated = translateKey(event.keyCode, event.modifierFlags)?.lowercased(),
       translated.count == 1,
       translated.allSatisfy(\.isASCII) {
        return translated
    }
    return normalizedCharacters(event).lowercased()
}

final class TextBoxInputTextView: NSTextView {
    private(set) var isHandlingDidChangeText = false

    var terminalTitle = ""
    var completionRootDirectory: String? {
        didSet {
            warmMentionCompletionIndexesIfNeeded()
            if oldValue != completionRootDirectory {
                refreshMentionCompletions()
            }
        }
    }
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onFocusTextBox: () -> Void = {}
    var onToggleFocus: () -> Void = {}
    var onForwardText: (String, Bool) -> Void = { _, _ in }
    var onForwardKey: (TextBoxTerminalKey) -> Void = { _ in }
    var onForwardControl: (String) -> Void = { _ in }
    var onPaste: (NSPasteboard, TextBoxInputTextView) -> Bool = { _, _ in false }
    var onInsertFileURLs: ([URL], TextBoxInputTextView) -> Bool = { _, _ in false }
    var onChooseFiles: () -> Void = {}
    var onMoveToWindow: (TextBoxInputTextView) -> Void = { _ in }
    var onLayoutCompleted: (TextBoxInputTextView) -> Void = { _ in }
    var onMarkedTextStateChanged: (Bool) -> Void = { _ in }
    var isReportingLayoutCompletion = false

    var attachmentPreviewPopover: NSPopover?
    var attachmentPreviewCharacterIndex: Int?
    var focusedAttachmentCharacterIndex: Int?
    var attachmentKeyDownMonitor: Any?
    var preserveAttachmentFocusOnNextResign = false
    var attachmentUploadInvalidationGeneration: UInt64 = 0
    var mentionCompletionPanel: TextBoxMentionCompletionPanel?
    var mentionCompletionPanelHost: NSHostingView<TextBoxMentionCompletionPopoverView>?
    var mentionCompletionControllerStorage: TextBoxMentionCompletionController?
    var warmedMentionCompletionRootDirectory: String?
    var mentionCompletionWarmupTask: Task<Void, Never>?
    var mentionCompletionWindowObserverTokens: [NSObjectProtocol] = []
    weak var mentionCompletionObservedWindow: NSWindow?
    var mentionCompletionRepositionIsScheduled = false
    var activeInsertTextDepth = 0
    var didChangeTextDuringActiveInsertText = false
    var pendingUndoableAttachmentFileCleanup: [String: TextBoxAttachment] = [:]
    var pendingAutomaticAttachmentFileCleanup: [String: TextBoxAttachment] = [:]
    var suppressAutomaticAttachmentFileCleanup = false
    deinit {
        mentionCompletionWarmupTask?.cancel()
        removeMentionCompletionWindowObservers()
        dismissMentionCompletions()
        removeAttachmentKeyDownMonitor()
        discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    override var acceptsFirstResponder: Bool { true }

    override func didChangeText() {
        if activeInsertTextDepth > 0 {
            didChangeTextDuringActiveInsertText = true
        }
        isHandlingDidChangeText = true
        defer { isHandlingDidChangeText = false }
        super.didChangeText()
        flushAutomaticAttachmentFileCleanup()
        refreshMentionCompletions()
    }

}
