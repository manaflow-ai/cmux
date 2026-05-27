import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

private enum TextBoxLayout {
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
    static let attachmentControlSpacing: CGFloat = 2
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

@MainActor
private final class TextBoxInputViewReference {
    weak var textView: TextBoxInputTextView?
    var filePanelFocusRestorer: TextBoxFilePanelFocusRestorer?
}

final class TextBoxFilePanelFocusRestorer {
    private weak var textView: TextBoxInputTextView?
    private weak var parentWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(textView: TextBoxInputTextView) {
        self.textView = textView
        self.parentWindow = textView.window
    }

    deinit {
        invalidate()
    }

    func install(parentWindow: NSWindow) {
        invalidate()
        self.parentWindow = parentWindow

        let notificationCenter = NotificationCenter.default
        observers = [
            notificationCenter.addObserver(
                forName: NSWindow.didEndSheetNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.restoreFocusAndInvalidate()
            },
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.restoreFocusAndInvalidate()
            }
        ]
    }

    @discardableResult
    func restoreFocusNow() -> Bool {
        guard let textView,
              let window = textView.window ?? parentWindow else {
            return false
        }
        return window.makeFirstResponder(textView)
    }

    func invalidate() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
    }

    private func restoreFocusAndInvalidate() {
        restoreFocusNow()
        invalidate()
    }
}

private struct TextBoxInputGlassPillBackground: View {
    let foreground: Color
    let fallbackTint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TextBoxLayout.pillCornerRadius, style: .continuous)

#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            shape
                .fill(Color.clear)
                .glassEffect(.regular.interactive(true), in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.24), lineWidth: 0.85)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        } else {
            fallback(shape)
        }
#else
        fallback(shape)
#endif
    }

    @ViewBuilder
    private func fallback(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(.regularMaterial)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            fallbackTint.opacity(0.20),
                            Color.black.opacity(0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.34),
                            foreground.opacity(0.16),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct TextBoxSendButtonStyle: ButtonStyle {
    let canSend: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed && canSend ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard canSend else {
            return Color.white.opacity(0.18)
        }
        return isPressed ? Color.white.opacity(0.68) : Color.white
    }
}

struct TextBoxAttachment: Identifiable {
    let id = UUID()
    let displayName: String
    let submissionText: String
    let submissionPath: String
    let localURL: URL?
    let thumbnail: NSImage?
    let cleanupLocalURLWhenDisposed: Bool

    init(
        displayName: String,
        submissionText: String,
        submissionPath: String,
        localURL: URL?,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = localURL?.standardizedFileURL
        let fallbackName = standardizedURL?.lastPathComponent ?? URL(fileURLWithPath: submissionPath).lastPathComponent
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackName.isEmpty ? submissionPath : fallbackName)
            : displayName
        self.submissionText = submissionText
        self.submissionPath = submissionPath
        self.localURL = standardizedURL
        self.thumbnail = standardizedURL.flatMap { TextBoxAttachment.makeThumbnail(for: $0) }
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }

    init(
        localURL: URL,
        submissionText: String,
        submissionPath: String? = nil,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = localURL.standardizedFileURL
        self.displayName = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path
            : standardizedURL.lastPathComponent
        self.submissionText = submissionText
        self.submissionPath = submissionPath ?? standardizedURL.path
        self.localURL = standardizedURL
        self.thumbnail = TextBoxAttachment.makeThumbnail(for: standardizedURL)
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }

    var isImage: Bool {
        if thumbnail != nil { return true }
        guard let localURL else { return false }
        return TextBoxAttachment.isImageFileURL(localURL)
    }

    var escapedSubmissionPath: String {
        TerminalImageTransferPlanner.escapeForShell(submissionPath)
    }

    var submitsLocalFilePath: Bool {
        guard let localURL else { return false }
        let standardizedLocalURL = localURL.standardizedFileURL
        return submissionPath == standardizedLocalURL.path
            || submissionText == Self.submissionText(forLocalFileURL: standardizedLocalURL)
    }

    static func submissionText(forLocalFileURL url: URL) -> String {
        TerminalImageTransferPlanner.insertedText(forFileURLs: [url.standardizedFileURL])
    }

    static func submissionText(forPath path: String) -> String {
        TerminalImageTransferPlanner.insertedText(forPathStrings: [path])
    }

    static func shouldCleanupLocalURLWhenDisposed(_ fileURL: URL) -> Bool {
        GhosttyPasteboardHelper.isOwnedTemporaryImageFile(fileURL)
            || TextBoxDraftAttachmentStorage.isOwnedDraftCopy(fileURL)
    }

    private static func makeThumbnail(for url: URL) -> NSImage? {
        guard TextBoxAttachment.isImageFileURL(url),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

private enum TextBoxDraftAttachmentStorage {
    private static let directoryName = "textbox-draft-attachments"
    private struct DraftCopyState {
        var copiedDraftPathByOriginalPath: [String: String] = [:]
        var pendingOriginalPaths: Set<String> = []
        var cancelledOriginalPaths: Set<String> = []
    }

    private nonisolated static let draftCopyState = OSAllocatedUnfairLock(
        initialState: DraftCopyState()
    )

    static func snapshot(for attachment: TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot {
        guard let localURL = attachment.localURL,
              GhosttyPasteboardHelper.isOwnedTemporaryImageFile(localURL) else {
            return fallbackSnapshot(for: attachment)
        }
        let standardizedLocalURL = localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedLocalURL.path) else {
            return fallbackSnapshot(for: attachment)
        }

        // Regular autosaves should not block the main thread on file copies.
        // Termination/update relaunch saves flush pending draft copies before
        // building the session snapshot so this lookup is already durable there.
        prepareDurableCopy(forTemporaryFileAtPath: standardizedLocalURL.path)
        guard let durableURL = copiedDraftURL(forOriginalURL: standardizedLocalURL) else {
            return fallbackSnapshot(for: attachment)
        }
        let submissionFields = copiedSubmissionFields(
            for: attachment,
            originalLocalURL: standardizedLocalURL,
            durableURL: durableURL
        )
        return SessionTextBoxInputAttachmentSnapshot(
            displayName: attachment.displayName,
            submissionText: submissionFields.text,
            submissionPath: submissionFields.path,
            localPath: durableURL.path,
            cleanupLocalPathWhenDisposed: true
        )
    }

    private static func fallbackSnapshot(for attachment: TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot {
        SessionTextBoxInputAttachmentSnapshot(
            displayName: attachment.displayName,
            submissionText: attachment.submissionText,
            submissionPath: attachment.submissionPath,
            localPath: attachment.localURL?.standardizedFileURL.path,
            cleanupLocalPathWhenDisposed: attachment.cleanupLocalURLWhenDisposed
        )
    }

    static func prepareDurableCopy(for attachment: TextBoxAttachment) {
        guard let localURL = attachment.localURL,
              GhosttyPasteboardHelper.isOwnedTemporaryImageFile(localURL) else {
            return
        }
        let standardizedLocalURL = localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedLocalURL.path) else { return }
        prepareDurableCopy(forTemporaryFileAtPath: standardizedLocalURL.path)
    }

    static func removeIfOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard isOwnedDraftCopy(fileURL) else { return false }
        try? FileManager.default.removeItem(at: fileURL.standardizedFileURL)
        return true
    }

    static func removeCopiedDraftForOriginalTemporaryFile(_ fileURL: URL) {
        let originalPath = fileURL.standardizedFileURL.path
        let copiedPath = draftCopyState.withLock { state in
            if state.pendingOriginalPaths.contains(originalPath) || state.cancelledOriginalPaths.contains(originalPath) {
                state.cancelledOriginalPaths.insert(originalPath)
            } else {
                state.cancelledOriginalPaths.remove(originalPath)
            }
            return state.copiedDraftPathByOriginalPath.removeValue(forKey: originalPath)
        }
        guard let copiedPath else { return }
        try? FileManager.default.removeItem(atPath: copiedPath)
    }

    private static func copiedDraftURL(forOriginalURL originalURL: URL) -> URL? {
        let copiedPath = draftCopyState.withLock { state in
            state.copiedDraftPathByOriginalPath[originalURL.standardizedFileURL.path]
        }
        guard let copiedPath else { return nil }
        let copiedURL = URL(fileURLWithPath: copiedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: copiedURL.path) else {
            _ = draftCopyState.withLock { state in
                state.copiedDraftPathByOriginalPath.removeValue(
                    forKey: originalURL.standardizedFileURL.path
                )
            }
            return nil
        }
        return copiedURL
    }

    private static func prepareDurableCopy(forTemporaryFileAtPath originalPath: String) {
        let originalPath = URL(fileURLWithPath: originalPath).standardizedFileURL.path
        let shouldStart = draftCopyState.withLock { state in
            guard state.copiedDraftPathByOriginalPath[originalPath] == nil,
                  !state.pendingOriginalPaths.contains(originalPath),
                  !state.cancelledOriginalPaths.contains(originalPath) else {
                return false
            }
            state.pendingOriginalPaths.insert(originalPath)
            return true
        }
        guard shouldStart else { return }

        let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
        if let durableURL = linkToDurableStorageIfPossible(originalURL) {
            draftCopyState.withLock { state in
                state.pendingOriginalPaths.remove(originalPath)
                state.cancelledOriginalPaths.remove(originalPath)
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
            }
            return
        }

        Task.detached(priority: .utility) {
            let durableURL = copyToDurableStorage(originalURL)
            let copiedPathToRemove = draftCopyState.withLock { state -> String? in
                guard state.pendingOriginalPaths.remove(originalPath) != nil else {
                    return nil
                }
                guard let durableURL else { return nil }
                if state.cancelledOriginalPaths.remove(originalPath) != nil {
                    return durableURL.path
                }
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
                return nil
            }
            if let copiedPathToRemove {
                try? FileManager.default.removeItem(atPath: copiedPathToRemove)
            }
        }
    }

    static func flushPendingCopiesSynchronously() {
        let pendingOriginalPaths = draftCopyState.withLock { state in
            Array(state.pendingOriginalPaths)
        }
        for originalPath in pendingOriginalPaths {
            let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
            let durableURL = linkToDurableStorageIfPossible(originalURL)
                ?? copyToDurableStorage(originalURL)
            let copiedPathToRemove = draftCopyState.withLock { state -> String? in
                guard state.pendingOriginalPaths.remove(originalPath) != nil else {
                    return nil
                }
                guard let durableURL else { return nil }
                if state.cancelledOriginalPaths.remove(originalPath) != nil {
                    return durableURL.path
                }
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
                return nil
            }
            if let copiedPathToRemove {
                try? FileManager.default.removeItem(atPath: copiedPathToRemove)
            }
        }
    }

    private static func copiedSubmissionFields(
        for attachment: TextBoxAttachment,
        originalLocalURL: URL,
        durableURL: URL
    ) -> (text: String, path: String) {
        let originalLocalURL = originalLocalURL.standardizedFileURL
        let originalLocalSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: originalLocalURL)
        guard attachment.submissionPath == originalLocalURL.path,
              attachment.submissionText == originalLocalSubmissionText else {
            return (attachment.submissionText, attachment.submissionPath)
        }
        return (TextBoxAttachment.submissionText(forLocalFileURL: durableURL), durableURL.path)
    }

    private static func copyToDurableStorage(_ sourceURL: URL) -> URL? {
        let sourceURL = sourceURL.standardizedFileURL
        guard let destinationURL = durableStorageURL(for: sourceURL) else { return nil }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL.standardizedFileURL
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL.standardizedFileURL
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                return destinationURL.standardizedFileURL
            }
            return nil
        }
    }

    private static func linkToDurableStorageIfPossible(_ sourceURL: URL) -> URL? {
        let sourceURL = sourceURL.standardizedFileURL
        guard let destinationURL = durableStorageURL(for: sourceURL) else { return nil }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                return destinationURL
            }
            return nil
        }
    }

    private static func durableStorageURL(for sourceURL: URL) -> URL? {
        guard let directory = storageDirectory() else { return nil }
        let sourceURL = sourceURL.standardizedFileURL
        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathToken = stablePathToken(sourceURL.path)
        let fallbackName = fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"
        let filename = "\(pathToken)-\(sourceURL.lastPathComponent.isEmpty ? fallbackName : sourceURL.lastPathComponent)"
        return directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
    }

    static func isOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard let directory = storageDirectory(createIfMissing: false) else { return false }
        let directoryPath = directory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private static func stablePathToken(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func storageDirectory(createIfMissing: Bool = true) -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }

#if DEBUG
    static func debugPrepareDurableCopySynchronously(for attachment: TextBoxAttachment) -> URL? {
        guard let localURL = attachment.localURL,
              GhosttyPasteboardHelper.isOwnedTemporaryImageFile(localURL) else {
            return nil
        }
        let originalURL = localURL.standardizedFileURL
        guard let durableURL = copyToDurableStorage(originalURL) else {
            return nil
        }
        draftCopyState.withLock { state in
            state.pendingOriginalPaths.remove(originalURL.path)
            state.cancelledOriginalPaths.remove(originalURL.path)
            state.copiedDraftPathByOriginalPath[originalURL.path] = durableURL.path
        }
        return durableURL
    }
#endif
}

#if DEBUG
extension TextBoxAttachment {
    func debugPrepareSessionDraftCopySynchronouslyForTesting() -> URL? {
        TextBoxDraftAttachmentStorage.debugPrepareDurableCopySynchronously(for: self)
    }

    func debugCancelSessionDraftCopyForTesting() {
        guard let localURL else { return }
        TextBoxDraftAttachmentStorage.removeCopiedDraftForOriginalTemporaryFile(localURL)
    }
}
#endif

extension TextBoxInputTextView {
    static func flushPendingSessionDraftAttachmentCopies() {
        TextBoxDraftAttachmentStorage.flushPendingCopiesSynchronously()
    }
}

enum TextBoxSubmissionPart {
    case text(String)
    case attachment(TextBoxAttachment)
}

extension SessionTextBoxInputAttachmentSnapshot {
    init(_ attachment: TextBoxAttachment) {
        self = TextBoxDraftAttachmentStorage.snapshot(for: attachment)
    }

    func textBoxAttachment() -> TextBoxAttachment {
        let restoredLocalURL: URL?
        if let localPath {
            let url = URL(fileURLWithPath: localPath).standardizedFileURL
            restoredLocalURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            restoredLocalURL = nil
        }
        return TextBoxAttachment(
            displayName: displayName,
            submissionText: submissionText,
            submissionPath: submissionPath,
            localURL: restoredLocalURL,
            cleanupLocalURLWhenDisposed: cleanupLocalPathWhenDisposed
        )
    }
}

private enum TextBoxSubmissionFormatter {
    static func parts(from attributed: NSAttributedString) -> [TextBoxSubmissionPart] {
        let raw = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: attributed.length)
        var parts: [TextBoxSubmissionPart] = []

        attributed.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if let inlineAttachment = value as? TextBoxInlineTextAttachment {
                parts.append(.attachment(inlineAttachment.textBoxAttachment))
            } else {
                let text = raw.substring(with: range)
                let strippedText = TextBoxInputTextView.stringByStrippingNonTextMarkers(from: text)
                guard !strippedText.isEmpty else { return }
                parts.append(.text(strippedText))
            }
        }

        return parts
    }

    static func formattedText(from parts: [TextBoxSubmissionPart]) -> String {
        var result = ""
        var attachmentNeedsBoundarySpace = false

        for part in parts {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if attachmentNeedsBoundarySpace,
                   text.first?.isWhitespace != true {
                    result += " "
                }
                result += text
                attachmentNeedsBoundarySpace = false
            case .attachment(let attachment):
                guard !attachment.submissionText.isEmpty else { continue }
                if attachmentNeedsBoundarySpace {
                    result += " "
                }
                result += attachment.submissionText
                attachmentNeedsBoundarySpace = result.last?.isWhitespace != true
            }
        }

        if attachmentNeedsBoundarySpace {
            result += " "
        }

        return result.trimmingCharacters(in: .newlines)
    }

    static func formattedText(from attributed: NSAttributedString) -> String {
        formattedText(from: parts(from: attributed))
    }

    static func hasSubmittableContent(_ parts: [TextBoxSubmissionPart]) -> Bool {
        parts.contains { part in
            switch part {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .attachment:
                return true
            }
        }
    }
}

struct TextBoxPasteboardRestorationToken: Equatable {
    let changeCount: Int
    let fileURL: URL
}

enum TextBoxPasteboardRestorationGuard {
    static func token(
        afterWritingTemporaryFileURL fileURL: URL,
        to pasteboard: NSPasteboard
    ) -> TextBoxPasteboardRestorationToken {
        TextBoxPasteboardRestorationToken(
            changeCount: pasteboard.changeCount,
            fileURL: fileURL.standardizedFileURL
        )
    }

    static func shouldRestore(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?
    ) -> Bool {
        guard let token else {
            return false
        }
        let temporaryPath = token.fileURL.standardizedFileURL.path
        let currentFileURLPaths = Set(
            PasteboardFileURLReader.fileURLs(from: pasteboard).map { $0.standardizedFileURL.path }
        )
        guard currentFileURLPaths.contains(temporaryPath) else {
            return false
        }
        guard pasteboard.changeCount == token.changeCount else {
            return currentFileURLPaths == [temporaryPath]
        }
        return true
    }

    static func isCurrentTemporaryWrite(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?
    ) -> Bool {
        shouldRestore(pasteboard: pasteboard, token: token)
    }
}

private final class TextBoxInlineTextAttachment: NSTextAttachment {
    let textBoxAttachment: TextBoxAttachment

    init(
        attachment: TextBoxAttachment,
        font: NSFont,
        foregroundColor: NSColor
    ) {
        self.textBoxAttachment = attachment
        super.init(data: nil, ofType: nil)
        refreshCell(font: font, foregroundColor: foregroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshCell(font: NSFont, foregroundColor: NSColor) {
        refreshCell(font: font, foregroundColor: foregroundColor, isFocused: false)
    }

    func refreshCell(font: NSFont, foregroundColor: NSColor, isFocused: Bool) {
        attachmentCell = TextBoxInlineAttachmentCell(
            attachment: textBoxAttachment,
            image: TextBoxInlineAttachmentRenderer.image(
                for: textBoxAttachment,
                font: font,
                foregroundColor: foregroundColor,
                isFocused: isFocused
            )
        )
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let width = attachmentCell?.cellSize().width ?? 1
        return NSRect(x: 0, y: 0, width: width, height: 1)
    }
}

private final class TextBoxInlineAttachmentCell: NSTextAttachmentCell {
    private let textBoxAttachment: TextBoxAttachment
    private let renderedImage: NSImage

    init(attachment: TextBoxAttachment, image: NSImage) {
        self.textBoxAttachment = attachment
        self.renderedImage = image
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func wantsToTrackMouse() -> Bool {
        true
    }

    override var cellSize: NSSize {
        NSSize(width: renderedImage.size.width, height: 1)
    }

    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard event.type == .leftMouseDown,
              let textView = controlView as? TextBoxInputTextView else {
            return false
        }

        let clickPoint = textView.convert(event.locationInWindow, from: nil)
        let drawnCellFrame = drawnFrame(for: cellFrame)
        let closeRect = NSRect(
            x: drawnCellFrame.maxX - TextBoxLayout.inlineAttachmentTrailingControlWidth - 6,
            y: drawnCellFrame.minY,
            width: TextBoxLayout.inlineAttachmentTrailingControlWidth + 6,
            height: drawnCellFrame.height
        )
        textView.handleInlineAttachmentCellClick(
            attachment: textBoxAttachment,
            characterIndex: charIndex,
            clickCount: event.clickCount,
            isCloseClick: closeRect.contains(clickPoint)
        )
        return true
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        renderedImage.draw(in: drawnFrame(for: cellFrame))
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        return NSRect(
            x: position.x,
            y: lineFrag.minY,
            width: renderedImage.size.width,
            height: lineFrag.height
        )
    }

    private func drawnFrame(for cellFrame: NSRect) -> NSRect {
        NSRect(
            x: cellFrame.minX,
            y: cellFrame.midY - renderedImage.size.height / 2 + TextBoxLayout.inlineAttachmentVerticalOffset,
            width: renderedImage.size.width,
            height: renderedImage.size.height
        )
    }
}

private enum TextBoxInlineAttachmentRenderer {
    static func image(
        for attachment: TextBoxAttachment,
        font: NSFont,
        foregroundColor: NSColor,
        isFocused: Bool
    ) -> NSImage {
        let textFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: foregroundColor.withAlphaComponent(0.90),
            .paragraphStyle: paragraph
        ]
        let textWidth = min(
            TextBoxLayout.inlineAttachmentMaxTextWidth,
            ceil((attachment.displayName as NSString).size(withAttributes: textAttributes).width)
        )
        let height = TextBoxLayout.attachmentChipHeight
        let iconSize = TextBoxLayout.attachmentImageSize
        let horizontalPadding: CGFloat = 6
        let iconTextGap: CGFloat = 4
        let width = horizontalPadding * 2
            + iconSize
            + iconTextGap
            + textWidth
            + TextBoxLayout.inlineAttachmentTrailingControlWidth

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(origin: .zero, size: image.size)
        let background = foregroundColor.withAlphaComponent(isFocused ? 0.16 : 0.10)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2).fill()

        let border = isFocused
            ? NSColor.controlAccentColor.withAlphaComponent(0.95)
            : foregroundColor.withAlphaComponent(0.14)
        border.setStroke()
        let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
        borderPath.lineWidth = isFocused ? 1.5 : 1
        borderPath.stroke()

        let iconRect = NSRect(
            x: horizontalPadding,
            y: (height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        if let thumbnail = attachment.thumbnail {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: iconRect, xRadius: 4, yRadius: 4).addClip()
            thumbnail.draw(in: iconRect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            icon?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))?
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.9)
        }

        let textSize = (attachment.displayName as NSString).size(withAttributes: textAttributes)

        let textRect = NSRect(
            x: iconRect.maxX + iconTextGap,
            y: (height - textSize.height) / 2,
            width: textWidth,
            height: textSize.height
        )
        (attachment.displayName as NSString).draw(in: textRect, withAttributes: textAttributes)

        let closeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: foregroundColor.withAlphaComponent(0.48)
        ]
        let closeString = "×" as NSString
        let closeSize = closeString.size(withAttributes: closeAttributes)
        closeString.draw(
            at: NSPoint(
                x: bounds.maxX - horizontalPadding - closeSize.width + 1,
                y: (height - closeSize.height) / 2
            ),
            withAttributes: closeAttributes
        )

        image.isTemplate = false
        return image
    }
}

private enum TextBoxAttachmentPreviewLayout {
    static let maxImageSize = CGSize(width: 408, height: 288)
    static let minImageSize = CGSize(width: 220, height: 140)
    static let cornerRadius: CGFloat = 14
    static let topButtonPadding: CGFloat = 8
    static let previewPadding: CGFloat = 8
    static let buttonTrailingPadding: CGFloat = 8
}

private struct TextBoxAttachmentPreviewMetrics {
    let imageSize: CGSize
    let contentSize: NSSize

    static func metrics(for attachment: TextBoxAttachment) -> TextBoxAttachmentPreviewMetrics {
        let imageSize = fittedImageSize(for: attachment)
        let padding = TextBoxAttachmentPreviewLayout.previewPadding
        return TextBoxAttachmentPreviewMetrics(
            imageSize: imageSize,
            contentSize: NSSize(
                width: imageSize.width + padding * 2,
                height: imageSize.height + padding * 2
            )
        )
    }

    private static func fittedImageSize(for attachment: TextBoxAttachment) -> CGSize {
        let fallback = CGSize(width: 260, height: 160)
        guard let image = attachment.thumbnail else { return fallback }

        let natural = naturalSize(for: image)
        guard natural.width > 0, natural.height > 0 else { return fallback }

        let minSize = TextBoxAttachmentPreviewLayout.minImageSize
        let maxSize = TextBoxAttachmentPreviewLayout.maxImageSize
        let maxScale = min(maxSize.width / natural.width, maxSize.height / natural.height)
        let needsMinimumSize = natural.width < minSize.width || natural.height < minSize.height
        let scale: CGFloat
        if needsMinimumSize {
            let minScale = max(minSize.width / natural.width, minSize.height / natural.height)
            scale = min(minScale, maxScale)
        } else {
            scale = min(1, maxScale)
        }
        return CGSize(
            width: max(1, floor(natural.width * scale)),
            height: max(1, floor(natural.height * scale))
        )
    }

    private static func naturalSize(for image: NSImage) -> CGSize {
        if let rep = image.representations.max(by: { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
}

private struct TextBoxAttachmentPreviewPopoverView: View {
    let attachment: TextBoxAttachment
    let imageSize: CGSize

    @State private var isPresented = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            previewContent
                .frame(width: imageSize.width, height: imageSize.height)
                .padding(TextBoxAttachmentPreviewLayout.previewPadding)

            if attachment.localURL != nil {
                Button(action: openInPreview) {
                    Text(String(localized: "textbox.openWithPreview.button", defaultValue: "Open with Preview"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(TextBoxAttachmentPreviewOpenButtonStyle())
                .help(String(localized: "textbox.openInPreview.tooltip", defaultValue: "Open in Preview"))
                .accessibilityLabel(String(localized: "textbox.openInPreview.tooltip", defaultValue: "Open in Preview"))
                .padding(.top, TextBoxAttachmentPreviewLayout.topButtonPadding)
                .padding(.trailing, TextBoxAttachmentPreviewLayout.buttonTrailingPadding)
            }
        }
        .frame(
            width: imageSize.width + TextBoxAttachmentPreviewLayout.previewPadding * 2,
            height: imageSize.height + TextBoxAttachmentPreviewLayout.previewPadding * 2
        )
        .clipShape(RoundedRectangle(cornerRadius: TextBoxAttachmentPreviewLayout.cornerRadius, style: .continuous))
        .background(Color.black.clipShape(RoundedRectangle(cornerRadius: TextBoxAttachmentPreviewLayout.cornerRadius, style: .continuous)))
        .overlay {
            RoundedRectangle(cornerRadius: TextBoxAttachmentPreviewLayout.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        .scaleEffect(isPresented ? 1 : 0.96, anchor: .bottom)
        .opacity(isPresented ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isPresented = true
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail = attachment.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: imageSize.width, height: imageSize.height)
                .background(Color.black.opacity(0.82))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 42, weight: .regular))
                Text(attachment.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.primary.opacity(0.86))
            .frame(width: imageSize.width, height: imageSize.height)
        }
    }

    private func openInPreview() {
        TextBoxAttachmentPreviewOpening.openInPreview(attachment)
    }
}

@MainActor
private enum TextBoxAttachmentPreviewOpening {
    static func openInPreview(_ attachment: TextBoxAttachment) {
        guard let url = attachment.localURL else { return }
        if let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct TextBoxAttachmentPreviewOpenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.78 : 0.94))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.22))
            }
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private final class TextBoxAttachmentPreviewController: NSHostingController<TextBoxAttachmentPreviewPopoverView> {

    init(attachment: TextBoxAttachment) {
        let metrics = TextBoxAttachmentPreviewMetrics.metrics(for: attachment)
        super.init(rootView: TextBoxAttachmentPreviewPopoverView(
            attachment: attachment,
            imageSize: metrics.imageSize
        ))
        preferredContentSize = metrics.contentSize
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct TextBoxAttachmentChip: View {
    let attachment: TextBoxAttachment
    let foreground: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: TextBoxLayout.attachmentImageSize,
                        height: TextBoxLayout.attachmentImageSize
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 12, weight: .medium))
                    .frame(
                        width: TextBoxLayout.attachmentImageSize,
                        height: TextBoxLayout.attachmentImageSize
                    )
            }

            Text(attachment.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 118, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(foreground.opacity(0.62))
            .help(String(localized: "textbox.removeAttachment.tooltip", defaultValue: "Remove Attachment"))
            .accessibilityLabel(String(localized: "textbox.removeAttachment.tooltip", defaultValue: "Remove Attachment"))
        }
        .foregroundStyle(foreground.opacity(0.88))
        .padding(.leading, 0)
        .padding(.trailing, 4)
        .frame(height: TextBoxLayout.attachmentChipHeight)
        .background(
            Capsule(style: .continuous)
                .fill(foreground.opacity(0.10))
        )
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

private enum TextBoxAgentDetection: CaseIterable {
    case claudeCode
    case codex
    case opencode

    private var definitionID: String {
        switch self {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .opencode:
            return "opencode"
        }
    }

    private var identityAliases: Set<String> {
        switch self {
        case .claudeCode:
            return ["claude", "claude_code", "claude-code", "claudecode", "omc"]
        case .codex:
            return ["codex", "omx"]
        case .opencode:
            return ["opencode", "open-code", "opencode-ai", "omo"]
        }
    }

    func matches(context: String) -> Bool {
        context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { matches(metadataLine: String($0)) }
    }

    static func supportsAgentPrefixes(context: String) -> Bool {
        allCases.contains { $0.matches(context: context) }
    }

    static func isClaudeCode(context: String) -> Bool {
        claudeCode.matches(context: context)
    }

    private func matches(metadataLine rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        if let value = Self.metadataValue(line, prefix: "restoredAgent:") {
            return matchesIdentity(value)
        }
        if let value = Self.metadataValue(line, prefix: "agentPIDKey:") {
            return matchesIdentity(value)
        }
        if let value = Self.metadataValue(line, prefix: "initialCommand:") {
            return matchesCommand(value)
        }
        if let value = Self.metadataValue(line, prefix: "tmuxStartCommand:") {
            return matchesCommand(value)
        }
        return false
    }

    private func matchesIdentity(_ rawValue: String) -> Bool {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if identityAliases.contains(normalized) {
            return true
        }
        let baseKey = normalized.split(separator: ".").first.map(String.init) ?? normalized
        return identityAliases.contains(baseKey)
    }

    private func matchesCommand(_ command: String) -> Bool {
        let tokens = Self.shellLikeTokens(command)
        guard !tokens.isEmpty else { return false }
        return Self.commandSegments(from: tokens).contains { segment in
            matchesCommandSegment(segment, depth: 0)
        }
    }

    private func matchesCommandSegment(_ tokens: [String], depth: Int) -> Bool {
        guard !tokens.isEmpty else { return false }
        let resolved = Self.resolvedCommandSegment(tokens)
        guard let executable = resolved.arguments.first else { return false }
        if CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: executable,
            processPath: executable,
            arguments: resolved.arguments,
            environment: resolved.environment
        )?.id == definitionID {
            return true
        }

        guard depth < 2 else { return false }
        return Self.shellSubcommandSegments(from: resolved.arguments).contains { segment in
            matchesCommandSegment(segment, depth: depth + 1)
        }
    }

    private static func metadataValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellLikeTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                flush()
                continue
            }
            current.append(character)
        }
        flush()
        return tokens
    }

    private static func commandSegments(from tokens: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for token in tokens {
            if token == "&&" || token == "||" || token == ";" {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func resolvedCommandSegment(_ tokens: [String]) -> (arguments: [String], environment: [String: String]) {
        var environment: [String: String] = [:]
        var index = 0
        let firstBasename = tokens.first.map { ($0 as NSString).lastPathComponent.lowercased() }

        if firstBasename == "env" {
            index = 1
            while index < tokens.count {
                let token = tokens[index]
                if token.hasPrefix("-") {
                    index += 1
                    continue
                }
                guard let assignment = environmentAssignment(token) else { break }
                environment[assignment.key] = assignment.value
                index += 1
            }
        } else {
            while index < tokens.count {
                guard let assignment = environmentAssignment(tokens[index]) else { break }
                environment[assignment.key] = assignment.value
                index += 1
            }
        }

        let arguments = Array(tokens.dropFirst(index))
        return (arguments.isEmpty ? tokens : arguments, environment)
    }

    private static func shellSubcommandSegments(from arguments: [String]) -> [[String]] {
        guard let executable = arguments.first else { return [] }
        let basename = (executable as NSString).lastPathComponent.lowercased()
        guard ["sh", "bash", "zsh", "fish"].contains(basename) else { return [] }

        var commandStartIndex: Int?
        for index in arguments.indices.dropFirst() {
            let argument = arguments[index]
            if argument == "-c" || argument == "-lc" || argument == "-cl" {
                commandStartIndex = arguments.index(after: index)
                break
            }
            if argument.hasPrefix("-"),
               !argument.hasPrefix("--"),
               argument.dropFirst().contains("c") {
                commandStartIndex = arguments.index(after: index)
                break
            }
        }

        guard let commandStartIndex,
              commandStartIndex < arguments.endIndex else {
            return []
        }
        let commandTokens = shellLikeTokens(arguments[commandStartIndex])
        guard !commandTokens.isEmpty else { return [] }
        return commandSegments(from: commandTokens)
    }

    private static func environmentAssignment(_ token: String) -> (key: String, value: String)? {
        guard let equalsIndex = token.firstIndex(of: "="),
              equalsIndex != token.startIndex else {
            return nil
        }
        let key = String(token[..<equalsIndex])
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (key, String(token[token.index(after: equalsIndex)...]))
    }
}

enum TextBoxMentionKind: Equatable, Sendable {
    case file
    case skill

    var defaultTrigger: Character {
        switch self {
        case .file:
            "@"
        case .skill:
            "/"
        }
    }
}

struct TextBoxMentionQuery: Equatable, Sendable {
    let kind: TextBoxMentionKind
    let location: Int
    let length: Int
    let query: String
    let trigger: Character

    var range: NSRange {
        NSRange(location: location, length: length)
    }

    init(kind: TextBoxMentionKind, range: NSRange, query: String, trigger: Character? = nil) {
        self.kind = kind
        location = range.location
        length = range.length
        self.query = query
        self.trigger = trigger ?? kind.defaultTrigger
    }
}

struct TextBoxMentionSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let insertionText: String
    let systemImageName: String
}

enum TextBoxMentionCompletionDetector {
    static func query(in text: String, selectedRange: NSRange) -> TextBoxMentionQuery? {
        guard selectedRange.length == 0,
              selectedRange.location != NSNotFound else {
            return nil
        }

        let nsText = text as NSString
        let cursor = min(max(0, selectedRange.location), nsText.length)
        guard cursor > 0 else { return nil }

        var tokenStart = cursor
        while tokenStart > 0 {
            let previous = nsText.substring(with: NSRange(location: tokenStart - 1, length: 1))
            if previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                break
            }
            tokenStart -= 1
        }

        guard tokenStart < cursor else { return nil }
        let tokenRange = NSRange(location: tokenStart, length: cursor - tokenStart)
        let token = nsText.substring(with: tokenRange)
        guard let trigger = token.first else { return nil }

        let kind: TextBoxMentionKind
        switch trigger {
        case "@":
            kind = .file
        case "/":
            kind = .skill
        case "$":
            kind = .skill
        default:
            return nil
        }

        guard token.allSatisfy({ character in
            character != "[" &&
                character != "]" &&
                character != "(" &&
                character != ")" &&
                character != "<" &&
                character != ">"
        }) else {
            return nil
        }

        let query = String(token.dropFirst())
        if kind == .skill, query.isEmpty {
            return nil
        }
        return TextBoxMentionQuery(kind: kind, range: tokenRange, query: query, trigger: trigger)
    }
}

private enum TextBoxMentionMarkdown {
    static func link(label: String, path: String) -> String {
        let escapedLabel = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escapedLabel)](\(markdownTarget(for: path)))"
    }

    private static func markdownTarget(for path: String) -> String {
        if path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
            path.contains("(") ||
            path.contains(")") {
            return "<\(path.replacingOccurrences(of: ">", with: "%3E"))>"
        }
        return path.replacingOccurrences(of: ")", with: "%29")
    }
}

private struct TextBoxMentionCandidate: Sendable {
    let title: String
    let subtitle: String
    let insertionText: String
    let systemImageName: String
    let searchKey: String
    let priority: Int

    func suggestion(trigger: Character) -> TextBoxMentionSuggestion {
        let displayTitle: String
        if (trigger == "/" || trigger == "$"), (title.hasPrefix("/") || title.hasPrefix("$")) {
            displayTitle = "\(trigger)\(title.dropFirst())"
        } else {
            displayTitle = title
        }

        return TextBoxMentionSuggestion(
            id: insertionText,
            title: displayTitle,
            subtitle: subtitle,
            insertionText: insertionText,
            systemImageName: systemImageName
        )
    }
}

private struct TextBoxMentionCandidateIndex: Sendable {
    private let corpus: [CommandPaletteSearchCorpusEntry<TextBoxMentionCandidate>]
    private let nucleoIndex: CommandPaletteNucleoSearchIndex<TextBoxMentionCandidate>?

    init(candidates: [TextBoxMentionCandidate]) {
        corpus = candidates.map { candidate in
            CommandPaletteSearchCorpusEntry(
                payload: candidate,
                rank: candidate.priority,
                title: candidate.title,
                searchableTexts: [
                    candidate.title,
                    candidate.subtitle,
                    candidate.searchKey
                ]
            )
        }
        nucleoIndex = corpus.count >= 32 ? CommandPaletteNucleoSearchIndex(entries: corpus) : nil
    }

    func rankedCandidates(matching rawQuery: String, limit: Int) -> [TextBoxMentionCandidate] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nucleoResults = nucleoIndex?.search(
            query: query,
            resultLimit: limit,
            historyBoost: { _, _ in 0 }
        ) {
            return nucleoResults.map(\.payload)
        }

        return CommandPaletteSearchEngine.search(
            entries: corpus,
            query: query,
            resultLimit: limit,
            historyBoost: { _, _ in 0 }
        )
        .map(\.payload)
    }
}

actor TextBoxMentionIndexStore {
    static let shared = TextBoxMentionIndexStore()

    private struct CachedIndex {
        let index: TextBoxMentionCandidateIndex
        let createdAt: Date
    }

    private static let fileIndexTTL: TimeInterval = 2
    private static let maxIndexedFiles = 6000
    private static let maxIndexedSkills = 800
    private static let suggestionLimit = 8
    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".next",
        ".swiftpm",
        ".vercel",
        "DerivedData",
        "Library",
        "node_modules",
        "Pods",
        "vendor"
    ]

    private var fileIndexesByRoot: [String: CachedIndex] = [:]
    private var skillIndexesByRootKey: [String: TextBoxMentionCandidateIndex] = [:]

    func suggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String?
    ) async -> [TextBoxMentionSuggestion] {
        switch query.kind {
        case .file:
            guard let rootDirectory = Self.normalizedDirectory(rootDirectory) else { return [] }
            return fileSuggestions(for: query, rootDirectory: rootDirectory)
        case .skill:
            let index = skillIndex(rootDirectory: Self.normalizedDirectory(rootDirectory))
            return index.rankedCandidates(matching: query.query, limit: Self.suggestionLimit)
                .map { $0.suggestion(trigger: query.trigger) }
        }
    }

    private func fileSuggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String
    ) -> [TextBoxMentionSuggestion] {
        let now = Date()
        let index = fileIndex(rootDirectory: rootDirectory, now: now)
        var matches = index.rankedCandidates(matching: query.query, limit: Self.suggestionLimit)
        if matches.isEmpty, !query.query.isEmpty {
            let refreshed = refreshFileIndex(rootDirectory: rootDirectory, now: now)
            matches = refreshed.rankedCandidates(matching: query.query, limit: Self.suggestionLimit)
        }
        return matches
            .map { $0.suggestion(trigger: query.trigger) }
    }

    private func fileIndex(
        rootDirectory: String,
        now: Date
    ) -> TextBoxMentionCandidateIndex {
        if let cached = fileIndexesByRoot[rootDirectory],
           now.timeIntervalSince(cached.createdAt) < Self.fileIndexTTL {
            return cached.index
        }
        return refreshFileIndex(rootDirectory: rootDirectory, now: now)
    }

    private func refreshFileIndex(
        rootDirectory: String,
        now: Date
    ) -> TextBoxMentionCandidateIndex {
        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let index = TextBoxMentionCandidateIndex(candidates: Self.scanFiles(rootURL: rootURL))
        fileIndexesByRoot[rootDirectory] = CachedIndex(index: index, createdAt: now)
        return index
    }

    private func skillIndex(rootDirectory: String?) -> TextBoxMentionCandidateIndex {
        let roots = Self.skillSearchRoots(rootDirectory: rootDirectory)
        let cacheKey = roots.map(\.path).joined(separator: "\n")
        if let cached = skillIndexesByRootKey[cacheKey] {
            return cached
        }

        var seenPaths = Set<String>()
        var candidates: [TextBoxMentionCandidate] = []
        for root in roots {
            for skillURL in Self.scanSkillFiles(rootURL: root) {
                let path = skillURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                let skillName = Self.skillName(from: skillURL)
                candidates.append(TextBoxMentionCandidate(
                    title: "/\(skillName)",
                    subtitle: Self.displayPath(path),
                    insertionText: TextBoxMentionMarkdown.link(label: "$\(skillName)", path: path),
                    systemImageName: "sparkle.magnifyingglass",
                    searchKey: "\(skillName) \(path)".lowercased(),
                    priority: 0
                ))
                if candidates.count >= Self.maxIndexedSkills {
                    break
                }
            }
            if candidates.count >= Self.maxIndexedSkills {
                break
            }
        }

        let index = TextBoxMentionCandidateIndex(candidates: candidates)
        skillIndexesByRootKey[cacheKey] = index
        return index
    }

    private static func scanFiles(rootURL: URL) -> [TextBoxMentionCandidate] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.path
        var candidates: [TextBoxMentionCandidate] = []
        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let relativePath = Self.relativePath(for: standardizedURL.path, rootPath: rootPath)
            candidates.append(TextBoxMentionCandidate(
                title: "@\(relativePath)",
                subtitle: Self.displayPath(standardizedURL.path),
                insertionText: TextBoxMentionMarkdown.link(label: "@\(relativePath)", path: standardizedURL.path),
                systemImageName: "doc",
                searchKey: "\(relativePath) \(name)".lowercased(),
                priority: min(relativePath.split(separator: "/").count, 20)
            ))

            if candidates.count >= maxIndexedFiles {
                break
            }
        }
        return candidates.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func scanSkillFiles(rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        var result: [URL] = []
        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("SKILL.md").path) {
            result.append(rootURL.appendingPathComponent("SKILL.md"))
            return result
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            if standardizedURL.lastPathComponent == "SKILL.md" {
                result.append(standardizedURL)
                if result.count >= maxIndexedSkills {
                    break
                }
                enumerator.skipDescendants()
                continue
            }

            if let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey]),
               values.isDirectory == true,
               skippedDirectoryNames.contains(standardizedURL.lastPathComponent) {
                enumerator.skipDescendants()
            }
        }
        return result
    }

    private static func skillSearchRoots(rootDirectory: String?) -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []

        if let rootDirectory {
            var current = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
            while current.path != "/" {
                let skillsURL = current.appendingPathComponent("skills", isDirectory: true)
                if fileManager.fileExists(atPath: skillsURL.path) {
                    roots.append(skillsURL)
                }
                current.deleteLastPathComponent()
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".codex/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".codex/skills/.system", isDirectory: true))
        roots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))
        roots.append(contentsOf: pluginSkillRoots(
            pluginCacheURL: home.appendingPathComponent(".codex/plugins/cache", isDirectory: true),
            fileManager: fileManager
        ))

        var seen = Set<String>()
        return roots
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.path).inserted }
    }

    private static func pluginSkillRoots(pluginCacheURL: URL, fileManager: FileManager) -> [URL] {
        guard let vendors = try? fileManager.contentsOfDirectory(
            at: pluginCacheURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var roots: [URL] = []
        for vendor in vendors where isDirectory(vendor, fileManager: fileManager) {
            guard let pluginNames = try? fileManager.contentsOfDirectory(
                at: vendor,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for pluginName in pluginNames where isDirectory(pluginName, fileManager: fileManager) {
                guard let versions = try? fileManager.contentsOfDirectory(
                    at: pluginName,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for version in versions where isDirectory(version, fileManager: fileManager) {
                    let skillsURL = version.appendingPathComponent("skills", isDirectory: true)
                    if isDirectory(skillsURL, fileManager: fileManager) {
                        roots.append(skillsURL)
                    }
                }
            }
        }
        return roots
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func skillName(from skillURL: URL) -> String {
        guard let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return skillURL.deletingLastPathComponent().lastPathComponent
        }

        for line in content.split(separator: "\n", maxSplits: 32, omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("name:") else { continue }
            let name = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return skillURL.deletingLastPathComponent().lastPathComponent
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.path
    }

    private static func relativePath(for path: String, rootPath: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        let relative = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : relative
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}

@MainActor
@Observable
private final class TextBoxMentionCompletionController {
    private(set) var suggestions: [TextBoxMentionSuggestion] = []
    private(set) var selectionIndex: Int = 0

    @ObservationIgnored
    private(set) var activeQuery: TextBoxMentionQuery?
    @ObservationIgnored
    private var activeRootDirectory: String?
    @ObservationIgnored
    private var lookupTask: Task<Void, Never>?
    @ObservationIgnored
    var onStateChanged: (() -> Void)?

    var hasSuggestions: Bool {
        !suggestions.isEmpty
    }

    var selectedSuggestion: TextBoxMentionSuggestion? {
        guard suggestions.indices.contains(selectionIndex) else { return nil }
        return suggestions[selectionIndex]
    }

    func refresh(for query: TextBoxMentionQuery?, rootDirectory: String?) {
        guard activeQuery != query || activeRootDirectory != rootDirectory else { return }
        activeQuery = query
        activeRootDirectory = rootDirectory
        selectionIndex = 0
        lookupTask?.cancel()
        suggestions = []
        onStateChanged?()

        guard let query else {
            return
        }

        lookupTask = Task { [weak self] in
            let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
                for: query,
                rootDirectory: rootDirectory
            )
            await MainActor.run {
                guard let self,
                      self.activeQuery == query,
                      self.activeRootDirectory == rootDirectory else {
                    return
                }
                self.suggestions = suggestions
                self.selectionIndex = suggestions.isEmpty ? 0 : min(self.selectionIndex, suggestions.count - 1)
                self.onStateChanged?()
            }
        }
    }

    func moveSelection(delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        selectionIndex = (selectionIndex + delta + count) % count
    }

    func clear() {
        activeQuery = nil
        activeRootDirectory = nil
        suggestions = []
        selectionIndex = 0
        lookupTask?.cancel()
        lookupTask = nil
        onStateChanged?()
    }

    deinit {
        lookupTask?.cancel()
    }

#if DEBUG
    func debugSetState(
        query: TextBoxMentionQuery?,
        suggestions debugSuggestions: [TextBoxMentionSuggestion]
    ) {
        lookupTask?.cancel()
        lookupTask = nil
        activeQuery = query
        activeRootDirectory = nil
        suggestions = debugSuggestions
        selectionIndex = suggestions.isEmpty ? 0 : min(selectionIndex, suggestions.count - 1)
        onStateChanged?()
    }

    var debugSuggestionCount: Int {
        suggestions.count
    }
#endif
}

private struct TextBoxMentionCompletionPopoverView: View {
    let controller: TextBoxMentionCompletionController
    let onSelect: (TextBoxMentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(controller.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.systemImageName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(suggestion.subtitle)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(index == controller.selectionIndex ? Color.accentColor.opacity(0.24) : Color.clear)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(width: 430)
        .background(.regularMaterial)
    }
}

@MainActor
protocol TextBoxSubmitSurfaceControlling: AnyObject {
    var clipboardReadGeneration: Int { get }
    var textBoxSubmitObservationWindow: NSWindow? { get }
    var textBoxSubmitTerminalSurface: TerminalSurface? { get }

    func visibleText() -> String?
    @discardableResult
    func sendKeyText(_ text: String) -> Bool
    @discardableResult
    func sendText(_ text: String) -> Bool
    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult
    @discardableResult
    func performBindingAction(_ action: String) -> Bool
}

extension TerminalSurface: TextBoxSubmitSurfaceControlling {
    var textBoxSubmitObservationWindow: NSWindow? {
        hostedView.window
    }

    var textBoxSubmitTerminalSurface: TerminalSurface? {
        self
    }
}

private extension TerminalSurface.NamedKeySendResult {
    var acceptedForTextBoxSubmit: Bool {
        switch self {
        case .sent, .queued:
            return true
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }
}

@MainActor
enum TextBoxSubmit {
    struct CompletionContext: Equatable {
        enum Failure: Equatable {
            case terminalWriteRejected
        }

        var confirmedClaudeImageSubmissionTexts: [String: Int] = [:]
        var failure: Failure?

        var didSubmit: Bool {
            failure == nil
        }

        static let empty = CompletionContext()
    }

#if DEBUG
    static var debugWaitTimeoutSecondsOverride: TimeInterval?

    static func debugRunDispatchEvents(
        _ events: [DispatchEvent],
        via surface: TextBoxSubmitSurfaceControlling,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
        TextBoxSubmitEventRunner.run(events, via: surface, onComplete: onComplete)
    }

    static func debugResetForTesting() {
        TextBoxSubmitEventRunner.resetForTesting()
        debugWaitTimeoutSecondsOverride = nil
    }
#endif

    private static let visibleTextWaitMaxCharacters = 160

    enum DispatchEvent: Equatable {
        case keyText(String)
        case pasteText(String)
        case pasteFilePath(String)
        case namedKeyRepeat(String, Int)
        case namedKey(String)
        case captureClipboardReadBaseline
        case waitForClipboardRead
        case captureVisibleTextBaseline
        case waitForVisibleText(String)
        case captureClaudeImageTokenBaseline
        case waitForClaudeImageToken(String)
    }

    static func submittedPasteText(for text: String) -> String? {
        let trimmedForEnabledState = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForEnabledState.isEmpty else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    static func submittedParts(_ parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPart]? {
        let flattened = parts.map { part in
            switch part {
            case .text(let text):
                return text
            case .attachment(let attachment):
                return attachment.submissionText
            }
        }.joined()
        guard !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return trimBoundaryNewlines(from: parts)
    }

    static func dispatchEvents(
        for parts: [TextBoxSubmissionPart],
        terminalAgentContext: String
    ) -> [DispatchEvent] {
        guard let inputParts = submittedParts(parts) else {
            return [.namedKey(TextBoxTerminalKey.returnKey.rawValue)]
        }

        let isClaude = TextBoxAgentDetection.isClaudeCode(context: terminalAgentContext)
        var containsNewline = false

        for part in inputParts {
            switch part {
            case .text(let text):
                if text.contains("\n") || text.contains("\r") {
                    containsNewline = true
                }
            case .attachment:
                break
            }
        }

        let submitKey = isClaude && containsNewline ? "ctrl+enter" : TextBoxTerminalKey.returnKey.rawValue
        if isClaude, containsImageAttachment(inputParts) {
            return claudeSequentialImageDispatchEvents(from: inputParts, submitKey: submitKey)
        }

        let pastePayload = TextBoxSubmissionFormatter.formattedText(from: inputParts)
        return [.pasteText(pastePayload), .namedKey(submitKey)]
    }

    static func send(
        _ text: String,
        via surface: TerminalSurface,
        terminalAgentContext: String,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
        let parts = submittedPasteText(for: text).map { [TextBoxSubmissionPart.text($0)] } ?? []
        send(parts, via: surface, terminalAgentContext: terminalAgentContext, onComplete: onComplete)
    }

    static func send(
        _ parts: [TextBoxSubmissionPart],
        via surface: TerminalSurface,
        terminalAgentContext: String,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
        let events = dispatchEvents(for: parts, terminalAgentContext: terminalAgentContext)
        TextBoxSubmitEventRunner.run(events, via: surface, onComplete: onComplete)
    }

    static func cleanupAttachmentsAfterSubmit(
        from parts: [TextBoxSubmissionPart],
        terminalAgentContext: String,
        completionContext: CompletionContext = .empty
    ) -> [TextBoxAttachment] {
        let isClaude = TextBoxAgentDetection.isClaudeCode(context: terminalAgentContext)
        var confirmedClaudeImageSubmissionTexts = completionContext.confirmedClaudeImageSubmissionTexts
        return parts.compactMap { part -> TextBoxAttachment? in
            if case .attachment(let attachment) = part { return attachment }
            return nil
        }.filter { attachment in
            guard attachment.cleanupLocalURLWhenDisposed else { return false }
            if isClaude, attachment.isImage {
                let remainingCount = confirmedClaudeImageSubmissionTexts[attachment.submissionText, default: 0]
                guard remainingCount > 0 else { return false }
                confirmedClaudeImageSubmissionTexts[attachment.submissionText] = remainingCount - 1
                return true
            }
            return !attachment.submitsLocalFilePath
        }
    }

    private static func containsImageAttachment(_ parts: [TextBoxSubmissionPart]) -> Bool {
        parts.contains { part in
            if case .attachment(let attachment) = part {
                return attachment.isImage
            }
            return false
        }
    }

    private static func claudeSequentialImageDispatchEvents(
        from parts: [TextBoxSubmissionPart],
        submitKey: String
    ) -> [DispatchEvent] {
        var events: [DispatchEvent] = []
        var attachmentNeedsBoundarySpace = false

        func appendPastedText(_ text: String) {
            guard !text.isEmpty else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.pasteText(text))
                return
            }
            events.append(.captureVisibleTextBaseline)
            events.append(.pasteText(text))
            if let waitNeedle = visibleTextWaitNeedle(for: text) {
                events.append(.waitForVisibleText(waitNeedle))
            }
        }

        func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            var textToPaste = text
            if attachmentNeedsBoundarySpace,
               text.first?.isWhitespace != true {
                textToPaste = " " + textToPaste
            }
            appendPastedText(textToPaste)
            attachmentNeedsBoundarySpace = false
        }

        for part in parts {
            switch part {
            case .text(let text):
                appendText(text)
            case .attachment(let attachment):
                guard !attachment.submissionText.isEmpty else { continue }
                if attachmentNeedsBoundarySpace {
                    appendPastedText(" ")
                }
                if attachment.isImage,
                   let pastePath = claudeImagePastePath(for: attachment) {
                    events.append(.captureClaudeImageTokenBaseline)
                    events.append(.captureClipboardReadBaseline)
                    events.append(.pasteFilePath(pastePath))
                    events.append(.waitForClipboardRead)
                    events.append(.waitForClaudeImageToken(attachment.submissionText))
                    attachmentNeedsBoundarySpace = true
                } else {
                    appendPastedText(attachment.submissionText)
                    attachmentNeedsBoundarySpace = attachment.submissionText.last?.isWhitespace != true
                }
            }
        }

        if attachmentNeedsBoundarySpace {
            appendPastedText(" ")
        }
        events.append(.namedKey(submitKey))
        return events
    }

    private static func visibleTextWaitNeedle(for text: String) -> String? {
        let nonNewlineTrimmed = text.trimmingCharacters(in: .newlines)
        guard !nonNewlineTrimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard nonNewlineTrimmed.count > visibleTextWaitMaxCharacters else {
            return text
        }

        let lastLine = nonNewlineTrimmed
            .split(omittingEmptySubsequences: false) { character in
                character == "\n" || character == "\r"
            }
            .last
            .map(String.init) ?? nonNewlineTrimmed
        let visibleLine = lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nonNewlineTrimmed
            : lastLine
        return String(visibleLine.suffix(visibleTextWaitMaxCharacters))
    }

    private static func claudeImagePastePath(for attachment: TextBoxAttachment) -> String? {
        guard attachment.isImage else { return nil }
        guard let localPath = attachment.localURL?.standardizedFileURL.path else { return nil }
        return attachment.submissionPath == localPath ? attachment.submissionPath : localPath
    }

    private static func trimBoundaryNewlines(from parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPart] {
        var result = parts

        while let first = result.first {
            guard case .text(let text) = first else { break }
            let trimmed = trimmingLeadingNewlines(text)
            if trimmed.isEmpty {
                result.removeFirst()
            } else {
                result[0] = .text(trimmed)
                break
            }
        }

        while let last = result.last {
            guard case .text(let text) = last else { break }
            let trimmed = trimmingTrailingNewlines(text)
            if trimmed.isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1] = .text(trimmed)
                break
            }
        }

        return result
    }

    private static func trimmingLeadingNewlines(_ text: String) -> String {
        String(text.drop { character in
            character == "\n" || character == "\r"
        })
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var result = text
        while let last = result.last,
              last == "\n" || last == "\r" {
            result.removeLast()
        }
        return result
    }

    static func visibleTextReady(
        expectedText: String,
        visibleText: String,
        baseline: String
    ) -> Bool {
        let trimmedExpectedText = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpectedText.isEmpty else {
            return visibleText != baseline
        }
        if occurrenceCount(of: expectedText, in: visibleText) >
            occurrenceCount(of: expectedText, in: baseline) {
            return true
        }

        let normalizedExpected = normalizedVisibleText(trimmedExpectedText)
        guard !normalizedExpected.isEmpty,
              normalizedExpected != expectedText else {
            return false
        }
        return occurrenceCount(of: normalizedExpected, in: normalizedVisibleText(visibleText)) >
            occurrenceCount(of: normalizedExpected, in: normalizedVisibleText(baseline))
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func normalizedVisibleText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
private final class TextBoxSubmitEventRunner {
    private static var active: [UUID: TextBoxSubmitEventRunner] = [:]
    private static var activeRunIDBySurface: [ObjectIdentifier: UUID] = [:]
    private static var queuedRunsBySurface: [ObjectIdentifier: [PendingRun]] = [:]
    private static var queuedSurfaceOrder: [ObjectIdentifier] = []
    private static var activePasteboardRunID: UUID?
    private static var isDrainingQueuedRuns = false

    private let id = UUID()
    private let events: [TextBoxSubmit.DispatchEvent]
    private let surface: TextBoxSubmitSurfaceControlling
    private let surfaceKey: ObjectIdentifier
    private let usesPasteboard: Bool
    private var onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?
    private var index = 0
    private var claudeImageTokenBaseline = 0
    private var visibleTextBaseline = ""
    private var clipboardReadBaseline = 0
    private var filePasteFallbackSatisfiedClipboardRead = false
    private var confirmedClaudeImageSubmissionTexts: [String: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var waitTimeoutTimer: DispatchSourceTimer?
    private var releaseTickNotifications: (() -> Void)?
    private var releaseRenderedFrameNotifications: (() -> Void)?
    private var originalPasteboardItems: [PasteboardItemSnapshot]?
    private var temporaryPasteboardRestorationToken: TextBoxPasteboardRestorationToken?
    private var observationToken = UUID()

    private static var waitTimeoutSeconds: TimeInterval {
#if DEBUG
        if let override = TextBoxSubmit.debugWaitTimeoutSecondsOverride {
            return max(0, override)
        }
#endif
        return 15
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct PendingRun {
        let events: [TextBoxSubmit.DispatchEvent]
        let surface: TextBoxSubmitSurfaceControlling
        let onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?
        let usesPasteboard: Bool

        init(
            events: [TextBoxSubmit.DispatchEvent],
            surface: TextBoxSubmitSurfaceControlling,
            onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?
        ) {
            self.events = events
            self.surface = surface
            self.onComplete = onComplete
            self.usesPasteboard = events.contains { event in
                if case .pasteFilePath = event { return true }
                return false
            }
        }
    }

    init(
        events: [TextBoxSubmit.DispatchEvent],
        surface: TextBoxSubmitSurfaceControlling,
        onComplete: ((TextBoxSubmit.CompletionContext) -> Void)?,
        usesPasteboard: Bool
    ) {
        self.events = events
        self.surface = surface
        self.surfaceKey = ObjectIdentifier(surface)
        self.onComplete = onComplete
        self.usesPasteboard = usesPasteboard
    }

    static func run(
        _ events: [TextBoxSubmit.DispatchEvent],
        via surface: TextBoxSubmitSurfaceControlling,
        onComplete: ((TextBoxSubmit.CompletionContext) -> Void)? = nil
    ) {
        let surfaceKey = ObjectIdentifier(surface)
        let pendingRun = PendingRun(events: events, surface: surface, onComplete: onComplete)
        guard activeRunIDBySurface[surfaceKey] == nil,
              queuedRunsBySurface[surfaceKey]?.isEmpty != false,
              !(pendingRun.usesPasteboard && activePasteboardRunID != nil) else {
            enqueue(pendingRun, for: surfaceKey)
#if DEBUG
            cmuxDebugLog("textbox.submit.queue surface=\(surfaceKey) count=\(queuedRunsBySurface[surfaceKey]?.count ?? 0)")
#endif
            return
        }
        start(pendingRun)
    }

    private static func start(_ pendingRun: PendingRun) {
        let runner = TextBoxSubmitEventRunner(
            events: pendingRun.events,
            surface: pendingRun.surface,
            onComplete: pendingRun.onComplete,
            usesPasteboard: pendingRun.usesPasteboard
        )
        active[runner.id] = runner
        activeRunIDBySurface[runner.surfaceKey] = runner.id
        if runner.usesPasteboard {
            activePasteboardRunID = runner.id
        }
        runner.processNext()
    }

    private static func enqueue(_ pendingRun: PendingRun, for surfaceKey: ObjectIdentifier) {
        if queuedRunsBySurface[surfaceKey]?.isEmpty != false,
           !queuedSurfaceOrder.contains(surfaceKey) {
            queuedSurfaceOrder.append(surfaceKey)
        }
        queuedRunsBySurface[surfaceKey, default: []].append(pendingRun)
    }

    private func processNext() {
        removeObservers()

        while index < events.count {
            let event = events[index]
#if DEBUG
            cmuxDebugLog("textbox.submit.event id=\(id.uuidString.prefix(5)) index=\(index) event=\(Self.debugDescription(for: event))")
#endif
            index += 1

            switch event {
            case .keyText(let text):
                guard surface.sendKeyText(text) else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .pasteText(let text):
                guard surface.sendText(text) else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .pasteFilePath(let path):
                guard pasteFilePath(path) else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .namedKeyRepeat(let key, let count):
                guard count > 0 else { continue }
                for _ in 0..<count {
                    guard surface.sendNamedKey(key).acceptedForTextBoxSubmit else {
                        fail(.terminalWriteRejected)
                        return
                    }
                }
            case .namedKey(let key):
                guard surface.sendNamedKey(key).acceptedForTextBoxSubmit else {
                    fail(.terminalWriteRejected)
                    return
                }
            case .captureClipboardReadBaseline:
                clipboardReadBaseline = surface.clipboardReadGeneration
                filePasteFallbackSatisfiedClipboardRead = false
            case .waitForClipboardRead:
                waitForClipboardRead()
                return
            case .captureVisibleTextBaseline:
                visibleTextBaseline = surface.visibleText() ?? ""
            case .waitForVisibleText(let expectedText):
                waitForVisibleText(expectedText)
                return
            case .captureClaudeImageTokenBaseline:
                claudeImageTokenBaseline = Self.claudeImageTokenCount(in: surface.visibleText() ?? "")
            case .waitForClaudeImageToken(let expectedText):
                waitForClaudeImageToken(expectedText)
                return
            }
        }

        finish()
    }

    private func fail(_ failure: TextBoxSubmit.CompletionContext.Failure) {
        removeObservers()
        restorePasteboardIfNeeded()
        let completion = onComplete
        onComplete = nil
        Self.active[id] = nil
        if Self.activeRunIDBySurface[surfaceKey] == id {
            Self.activeRunIDBySurface[surfaceKey] = nil
        }
        if Self.activePasteboardRunID == id {
            Self.activePasteboardRunID = nil
        }
        completion?(TextBoxSubmit.CompletionContext(
            confirmedClaudeImageSubmissionTexts: confirmedClaudeImageSubmissionTexts,
            failure: failure
        ))
        Self.startQueuedRuns()
    }

    private func finish() {
        restorePasteboardIfNeeded()
        let completion = onComplete
        onComplete = nil
        Self.active[id] = nil
        if Self.activeRunIDBySurface[surfaceKey] == id {
            Self.activeRunIDBySurface[surfaceKey] = nil
        }
        if Self.activePasteboardRunID == id {
            Self.activePasteboardRunID = nil
        }
        completion?(TextBoxSubmit.CompletionContext(
            confirmedClaudeImageSubmissionTexts: confirmedClaudeImageSubmissionTexts
        ))
        Self.startQueuedRuns()
    }

    private static func startQueuedRuns() {
        guard !isDrainingQueuedRuns else { return }
        isDrainingQueuedRuns = true
        defer { isDrainingQueuedRuns = false }

        var madeProgress = true
        while madeProgress {
            madeProgress = false
            var index = 0
            while index < queuedSurfaceOrder.count {
                let surfaceKey = queuedSurfaceOrder[index]
                if activeRunIDBySurface[surfaceKey] != nil {
                    index += 1
                    continue
                }

                guard var queuedRuns = queuedRunsBySurface[surfaceKey],
                      let nextRun = queuedRuns.first else {
                    queuedRunsBySurface[surfaceKey] = nil
                    queuedSurfaceOrder.remove(at: index)
                    continue
                }
                if nextRun.usesPasteboard, activePasteboardRunID != nil {
                    index += 1
                    continue
                }

                queuedRuns.removeFirst()
                if queuedRuns.isEmpty {
                    queuedRunsBySurface[surfaceKey] = nil
                    queuedSurfaceOrder.remove(at: index)
                } else {
                    queuedRunsBySurface[surfaceKey] = queuedRuns
                    index += 1
                }
                madeProgress = true
                start(nextRun)
            }
        }
    }

#if DEBUG
    static func resetForTesting() {
        for runner in active.values {
            runner.cancelForTesting()
        }
        active.removeAll()
        activeRunIDBySurface.removeAll()
        queuedRunsBySurface.removeAll()
        queuedSurfaceOrder.removeAll()
        activePasteboardRunID = nil
        isDrainingQueuedRuns = false
    }

    private func cancelForTesting() {
        removeObservers()
        restorePasteboardIfNeeded()
        onComplete = nil
    }
#endif

    private func waitForVisibleText(_ expectedText: String) {
        if visibleTextReady(expectedText) {
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.visible.ready id=\(id.uuidString.prefix(5)) expected=\(Self.debugText(expectedText))")
#endif
            processNext()
            return
        }

        observeTerminalUpdates { [weak self] in
            guard let self,
                  self.visibleTextReady(expectedText) else {
                return false
            }
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.visible.observed id=\(self.id.uuidString.prefix(5)) expected=\(Self.debugText(expectedText))")
#endif
            self.processNext()
            return true
        } onExhausted: { [weak self] in
            guard let self else { return }
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.visible.exhausted.continuing id=\(self.id.uuidString.prefix(5)) expected=\(Self.debugText(expectedText))")
#endif
            self.processNext()
        }
    }

    private func waitForClipboardRead() {
        if filePasteFallbackSatisfiedClipboardRead {
            filePasteFallbackSatisfiedClipboardRead = false
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.clipboard.fallback id=\(id.uuidString.prefix(5)) baseline=\(clipboardReadBaseline)")
#endif
            processNext()
            return
        }

        if clipboardReadReady() {
#if DEBUG
            cmuxDebugLog("textbox.submit.wait.clipboard.ready id=\(id.uuidString.prefix(5)) baseline=\(clipboardReadBaseline)")
#endif
            processNext()
            return
        }

        guard let token = observeTerminalUpdates(
            { [weak self] in
                guard let self else { return false }
                if self.filePasteFallbackSatisfiedClipboardRead {
                    self.filePasteFallbackSatisfiedClipboardRead = false
#if DEBUG
                    cmuxDebugLog("textbox.submit.wait.clipboard.fallback.observed id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                    self.processNext()
                    return true
                }
                guard self.clipboardReadReady() else {
                    return false
                }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.clipboard.observed id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                self.processNext()
                return true
            },
            onExhausted: { [weak self] in
                guard let self else { return }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.clipboard.exhausted.continuing id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                self.processNext()
            },
            performInitialCheck: false
        ) else {
            return
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidCompleteClipboardRead,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.observationToken == token else { return }
                if let notificationSurface = notification.object as AnyObject? {
                    guard notificationSurface === self.surface as AnyObject else { return }
                }
                guard self.clipboardReadReady() else { return }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.clipboard.notification id=\(self.id.uuidString.prefix(5)) baseline=\(self.clipboardReadBaseline)")
#endif
                self.processNext()
            }
        })

        if clipboardReadReady() {
            processNext()
        }
    }

    private func waitForClaudeImageToken(_ expectedText: String) {
        if claudeImageTokenReady() {
#if DEBUG
            cmuxDebugLog(
                "textbox.submit.wait.image.ready id=\(id.uuidString.prefix(5)) " +
                "baseline=\(claudeImageTokenBaseline) expected=\(Self.debugText(expectedText))"
            )
#endif
            markClaudeImageTokenConfirmed(expectedText)
            processNext()
            return
        }

        observeTerminalUpdates { [weak self] in
            guard let self,
                  self.claudeImageTokenReady() else {
                return false
            }
#if DEBUG
            cmuxDebugLog(
                "textbox.submit.wait.image.observed id=\(self.id.uuidString.prefix(5)) " +
                "baseline=\(self.claudeImageTokenBaseline) expected=\(Self.debugText(expectedText))"
            )
#endif
            self.markClaudeImageTokenConfirmed(expectedText)
            self.processNext()
            return true
        } onExhausted: { [weak self] in
            guard let self else { return }
#if DEBUG
            cmuxDebugLog(
                "textbox.submit.wait.image.exhausted.continuing id=\(self.id.uuidString.prefix(5)) " +
                "baseline=\(self.claudeImageTokenBaseline) expected=\(Self.debugText(expectedText))"
            )
#endif
            self.processNext()
        }
    }

    private func markClaudeImageTokenConfirmed(_ expectedText: String) {
        confirmedClaudeImageSubmissionTexts[expectedText, default: 0] += 1
    }

    @discardableResult
    private func observeTerminalUpdates(
        _ check: @escaping @MainActor () -> Bool,
        onExhausted: (@MainActor () -> Void)? = nil,
        performInitialCheck: Bool = true
    ) -> UUID? {
        let center = NotificationCenter.default
        releaseTickNotifications = GhosttyApp.retainTickNotifications()
        releaseRenderedFrameNotifications = GhosttyNSView.retainRenderedFrameNotifications()
        let token = UUID()
        observationToken = token
        armObservationTimeout(
            token: token,
            timeoutSeconds: Self.waitTimeoutSeconds,
            onExhausted: onExhausted
        )

        @MainActor
        func checkIfCurrent() {
            guard observationToken == token else { return }
            let didComplete = check()
            guard !didComplete, observationToken == token else {
                return
            }
        }

        observers.append(center.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self != nil else { return }
                checkIfCurrent()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let surfaceView = notification.object as? GhosttyNSView {
                    guard let expectedSurface = self.surface.textBoxSubmitTerminalSurface,
                          surfaceView.terminalSurface === expectedSurface else {
                        return
                    }
                }
                checkIfCurrent()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let surfaceView = notification.object as? GhosttyNSView {
                    guard let expectedSurface = self.surface.textBoxSubmitTerminalSurface,
                          surfaceView.terminalSurface === expectedSurface else {
                        return
                    }
                }
                checkIfCurrent()
            }
        })

        if let window = surface.textBoxSubmitObservationWindow {
            observers.append(center.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self != nil else { return }
                checkIfCurrent()
            }
        })
        }

        if performInitialCheck {
            checkIfCurrent()
        }
        guard Self.active[id] === self,
              observationToken == token else {
            return nil
        }
        GhosttyApp.shared.scheduleTick()
        return token
    }

    private func armObservationTimeout(
        token: UUID,
        timeoutSeconds: TimeInterval,
        onExhausted: (@MainActor () -> Void)?
    ) {
        waitTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        waitTimeoutTimer = timer
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.observationToken == token else {
                    return
                }
#if DEBUG
                cmuxDebugLog("textbox.submit.wait.timeout id=\(self.id.uuidString.prefix(5))")
#endif
                onExhausted?()
            }
        }
        timer.resume()
    }

    private func pasteFilePath(_ path: String) -> Bool {
        let pasteboard = NSPasteboard.general
        if originalPasteboardItems == nil {
            originalPasteboardItems = Self.snapshotPasteboardItems(pasteboard)
        } else if !TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
            pasteboard: pasteboard,
            token: temporaryPasteboardRestorationToken
        ) {
            originalPasteboardItems = Self.snapshotPasteboardItems(pasteboard)
            temporaryPasteboardRestorationToken = nil
        }

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        pasteboard.clearContents()
        let wroteURL = pasteboard.writeObjects([fileURL as NSURL])
        if !wroteURL {
            pasteboard.clearContents()
            pasteboard.declareTypes([.fileURL, PasteboardFileURLReader.legacyFilenamesPboardType], owner: nil)
            _ = pasteboard.setString(fileURL.absoluteString, forType: .fileURL)
            _ = pasteboard.setPropertyList([fileURL.path], forType: PasteboardFileURLReader.legacyFilenamesPboardType)
        }
        temporaryPasteboardRestorationToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )

#if DEBUG
        cmuxDebugLog(
            "textbox.submit.pasteFile id=\(id.uuidString.prefix(5)) pathLength=\(fileURL.path.utf8.count) wroteURL=\(wroteURL ? 1 : 0) " +
            "types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ","))"
        )
#endif

        let handled = surface.performBindingAction("paste_from_clipboard")
#if DEBUG
        cmuxDebugLog("textbox.submit.pasteFile.binding id=\(id.uuidString.prefix(5)) handled=\(handled ? 1 : 0)")
#endif
        if handled {
            return true
        } else {
            filePasteFallbackSatisfiedClipboardRead = true
            let sentFallback = surface.sendText(TerminalImageTransferPlanner.escapeForShell(path))
            restorePasteboardIfNeeded()
            return sentFallback
        }
    }

    private func restorePasteboardIfNeeded() {
        guard let originalPasteboardItems else { return }
        self.originalPasteboardItems = nil
        let pasteboard = NSPasteboard.general
        guard TextBoxPasteboardRestorationGuard.shouldRestore(
            pasteboard: pasteboard,
            token: temporaryPasteboardRestorationToken
        ) else {
            temporaryPasteboardRestorationToken = nil
            return
        }
        temporaryPasteboardRestorationToken = nil
        pasteboard.clearContents()
        guard !originalPasteboardItems.isEmpty else { return }
        let restoredItems = originalPasteboardItems.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private static func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type: type, data: data)
                }
            )
        }
    }

    private func claudeImageTokenReady() -> Bool {
        Self.claudeImageTokenCount(in: surface.visibleText() ?? "") > claudeImageTokenBaseline
    }

    private func clipboardReadReady() -> Bool {
        surface.clipboardReadGeneration > clipboardReadBaseline
    }

    private func visibleTextReady(_ expectedText: String) -> Bool {
        let visibleText = surface.visibleText() ?? ""
        return TextBoxSubmit.visibleTextReady(
            expectedText: expectedText,
            visibleText: visibleText,
            baseline: visibleTextBaseline
        )
    }

    private static func claudeImageTokenCount(in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "[Image #", range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

#if DEBUG
    private static func debugDescription(for event: TextBoxSubmit.DispatchEvent) -> String {
        switch event {
        case .keyText(let text):
            return "keyText(\(debugText(text)))"
        case .pasteText(let text):
            return "pasteText(\(debugText(text)))"
        case .pasteFilePath(let path):
            return "pasteFilePath(length:\(path.utf8.count))"
        case .namedKeyRepeat(let key, let count):
            return "namedKeyRepeat(\(key),\(count))"
        case .namedKey(let key):
            return "namedKey(\(key))"
        case .captureClipboardReadBaseline:
            return "captureClipboardReadBaseline"
        case .waitForClipboardRead:
            return "waitForClipboardRead"
        case .captureVisibleTextBaseline:
            return "captureVisibleTextBaseline"
        case .waitForVisibleText(let text):
            return "waitForVisibleText(\(debugText(text)))"
        case .captureClaudeImageTokenBaseline:
            return "captureClaudeImageTokenBaseline"
        case .waitForClaudeImageToken(let text):
            return "waitForClaudeImageToken(\(debugText(text)))"
        }
    }

    private static func debugText(_ text: String) -> String {
        "length:\(text.utf8.count),hasNewlines:\(text.contains(where: \.isNewline) ? 1 : 0)"
    }
#endif

    private func removeObservers() {
        observationToken = UUID()
        waitTimeoutTimer?.cancel()
        waitTimeoutTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
        releaseTickNotifications?()
        releaseTickNotifications = nil
        releaseRenderedFrameNotifications?()
        releaseRenderedFrameNotifications = nil
    }
}

struct TextBoxInputContainer: View {
    @Binding var text: String
    @Binding var attachments: [TextBoxAttachment]
    let surface: TerminalSurface
    let terminalBackgroundColor: NSColor
    let terminalForegroundColor: NSColor
    let terminalFont: NSFont
    let maxLines: Int
    let terminalAgentContext: String
    let onFocusTextBox: () -> Void
    let onToggleFocus: () -> Void
    let onEscape: () -> Void
    let onTextViewCreated: (TextBoxInputTextView) -> Void
    let onTextViewMovedToWindow: (TextBoxInputTextView) -> Void
    let onTextViewDismantled: (TextBoxInputTextView) -> Void

    @State private var textViewHeight: CGFloat = 0
    @State private var hasPendingAttachmentUpload = false
    @State private var textViewReference = TextBoxInputViewReference()
    @State private var contentRevision: UInt64 = 0

    private var textFont: NSFont {
        NSFont.systemFont(ofSize: max(14, terminalFont.pointSize + 2), weight: .regular)
    }

    private func heightForLines(_ lines: Int) -> CGFloat {
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        let lineSpacing = CGFloat(max(0, lines - 1)) * TextBoxLayout.lineSpacing
        let inset = TextBoxLayout.textInset(forLineCount: lines)
        return lineHeight * CGFloat(lines) + lineSpacing + inset.height * 2
    }

    private var completionRootDirectory: String? {
        guard let workspace = surface.owningWorkspace() else { return nil }
        if let directory = workspace.panelDirectories[surface.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        if let directory = workspace.terminalPanel(for: surface.id)?
            .requestedWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }

    var body: some View {
        let minHeight = max(TextBoxLayout.minimumTextHeight, heightForLines(TextBoxLayout.minLines))
        let maxHeight = heightForLines(max(TextBoxLayout.minLines, maxLines))
        let clampedHeight = max(minHeight, min(maxHeight, textViewHeight))
        let foreground = Color(nsColor: terminalForegroundColor)
        let background = Color(nsColor: terminalBackgroundColor)
        let canSend = !hasPendingAttachmentUpload
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)

        HStack(alignment: .bottom, spacing: 6) {
            addFilesButton(foreground: foreground)
                .offset(x: TextBoxLayout.leadingButtonHorizontalOffset)
                .padding(.bottom, TextBoxLayout.buttonBottomPadding)

            ZStack(alignment: .leading) {
                TextBoxInputView(
                    text: $text,
                    attachments: $attachments,
                    textViewHeight: $textViewHeight,
                    hasPendingAttachmentUpload: $hasPendingAttachmentUpload,
                    font: textFont,
                    backgroundColor: terminalBackgroundColor,
                    foregroundColor: terminalForegroundColor,
                    terminalTitle: terminalAgentContext,
                    completionRootDirectory: completionRootDirectory,
                    onSubmit: submit,
                    onEscape: onEscape,
                    onFocusTextBox: onFocusTextBox,
                    onToggleFocus: onToggleFocus,
                    onForwardText: forwardText(_:focusTerminalAfterSend:),
                    onForwardKey: forwardKey(_:),
                    onForwardControl: forwardControl(_:),
                    onPaste: handlePaste(_:into:),
                    onInsertFileURLs: insertSelectedFileURLs(_:into:),
                    onChooseFiles: chooseFiles,
                    onContentChanged: markContentChanged,
                    onTextViewCreated: registerTextView(_:),
                    onTextViewMovedToWindow: onTextViewMovedToWindow,
                    onTextViewDismantled: onTextViewDismantled
                )

                if text.isEmpty && attachments.isEmpty {
                    Text(String(localized: "textbox.placeholder", defaultValue: "Prompt or command"))
                        .font(.system(size: textFont.pointSize))
                        .foregroundStyle(Color(nsColor: terminalForegroundColor).opacity(0.36))
                        .padding(.leading, TextBoxLayout.textInset.width)
                        .frame(height: clampedHeight, alignment: .center)
                        .offset(y: TextBoxLayout.placeholderVerticalOffset)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: clampedHeight)
            .frame(maxWidth: .infinity)

            sendButton(canSend: canSend, foreground: foreground)
                .offset(x: TextBoxLayout.trailingButtonHorizontalOffset)
                .padding(.bottom, TextBoxLayout.buttonBottomPadding)
        }
        .padding(.horizontal, TextBoxLayout.pillHorizontalPadding)
        .padding(.vertical, TextBoxLayout.pillVerticalPadding)
        .background(
            TextBoxInputGlassPillBackground(
                foreground: foreground,
                fallbackTint: background
            )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func addFilesButton(foreground: Color) -> some View {
        Button(action: chooseFiles) {
            Image(systemName: "plus")
                .font(.system(size: TextBoxLayout.iconSymbolSize, weight: .semibold))
                .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
                .background(
                    Circle()
                        .fill(foreground.opacity(0.10))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground.opacity(0.82))
        .help(String(localized: "textbox.addFiles.tooltip", defaultValue: "Add Files"))
        .accessibilityLabel(String(localized: "textbox.addFiles.tooltip", defaultValue: "Add Files"))
        .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
    }

    private func attachmentStrip(foreground: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(attachments) { attachment in
                    TextBoxAttachmentChip(
                        attachment: attachment,
                        foreground: foreground,
                        onRemove: {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    )
                }
            }
        }
        .frame(maxWidth: 280)
        .frame(height: TextBoxLayout.attachmentChipHeight)
    }

    private func sendButton(canSend: Bool, foreground: Color) -> some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: TextBoxLayout.sendSymbolSize, weight: .bold))
                .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
        }
        .buttonStyle(TextBoxSendButtonStyle(canSend: canSend))
        .foregroundStyle(canSend ? Color.black.opacity(0.86) : foreground.opacity(0.38))
        .help(String(localized: "textbox.send.tooltip", defaultValue: "Send"))
        .accessibilityLabel(String(localized: "textbox.send.tooltip", defaultValue: "Send"))
        .disabled(!canSend)
        .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
    }

    private func submit() {
        guard textViewReference.textView?.hasPendingAttachmentUploadPlaceholder() != true else {
            NSSound.beep()
            return
        }

        let submittedParts = textViewReference.textView?.submissionParts()
            ?? [TextBoxSubmissionPart.text(text.trimmingCharacters(in: .newlines))]
        guard TextBoxSubmissionFormatter.hasSubmittableContent(submittedParts) else {
            NSSound.beep()
            return
        }
        let submittedTextView = textViewReference.textView
        let preservedContent = submittedTextView?.attributedContentForPreservation()
        submittedTextView?.prepareForSubmit()
        submittedTextView?.clearContent(cleanupAttachmentFiles: false)
        text = ""
        attachments = []
        hasPendingAttachmentUpload = false
        textViewHeight = 0
        let rollbackSnapshot = TextBoxFailedSubmitRollbackSnapshot(
            revision: advanceContentRevision(),
            text: "",
            attachmentCount: 0
        )
        TextBoxSubmit.send(
            submittedParts,
            via: surface,
            terminalAgentContext: terminalAgentContext
        ) { completionContext in
            guard completionContext.didSubmit else {
                guard TextBoxFailedSubmitRollbackPolicy.shouldRestore(
                    rollbackSnapshot: rollbackSnapshot,
                    currentSnapshot: currentRollbackSnapshot()
                ) else {
                    NSSound.beep()
                    return
                }
                if let preservedContent {
                    submittedTextView?.installPreservedContent(preservedContent)
                } else {
                    text = TextBoxSubmissionFormatter.formattedText(from: submittedParts)
                    attachments = submittedParts.compactMap { part in
                        if case .attachment(let attachment) = part { return attachment }
                        return nil
                    }
                }
                NSSound.beep()
                return
            }
            let submittedAttachments = submittedParts.compactMap { part -> TextBoxAttachment? in
                if case .attachment(let attachment) = part { return attachment }
                return nil
            }
            submittedTextView?.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions(submittedAttachments)
            let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: submittedParts,
                terminalAgentContext: terminalAgentContext,
                completionContext: completionContext
            )
            submittedTextView?.cleanupDisposableAttachmentFiles(cleanupAttachments)
        }
    }

    private func markContentChanged() {
        _ = advanceContentRevision()
    }

    @discardableResult
    private func advanceContentRevision() -> UInt64 {
        contentRevision &+= 1
        return contentRevision
    }

    private func currentRollbackSnapshot() -> TextBoxFailedSubmitRollbackSnapshot {
        let currentTextView = textViewReference.textView
        return TextBoxFailedSubmitRollbackSnapshot(
            revision: contentRevision,
            text: currentTextView?.plainText() ?? text,
            attachmentCount: currentTextView?.inlineAttachments().count ?? attachments.count
        )
    }

    private func registerTextView(_ textView: TextBoxInputTextView) {
        textViewReference.textView = textView
        onTextViewCreated(textView)
    }

    private func chooseFiles() {
        guard let textView = textViewReference.textView else {
            NSSound.beep()
            return
        }

        focusTextViewAfterFilePanel(textView)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "textbox.addFiles.panel.title", defaultValue: "Add Files")
        panel.prompt = String(localized: "textbox.addFiles.panel.prompt", defaultValue: "Add")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            focusTextViewAfterFilePanel(textView)
            guard response == .OK else { return }
            if !insertSelectedFileURLs(panel.urls, into: textView) {
                NSSound.beep()
                focusTextViewAfterFilePanel(textView)
            }
        }

        if let window = textView.window {
            installFilePanelFocusRestorer(for: textView, parentWindow: window)
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    private func focusTextViewAfterFilePanel(_ textView: TextBoxInputTextView) {
        textView.window?.makeFirstResponder(textView)
    }

    private func installFilePanelFocusRestorer(for textView: TextBoxInputTextView, parentWindow: NSWindow) {
        let restorer = TextBoxFilePanelFocusRestorer(textView: textView)
        restorer.install(parentWindow: parentWindow)
        textViewReference.filePanelFocusRestorer = restorer
    }

    private func insertSelectedFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        return insertPreparedContent(.fileURLs(standardizedURLs), into: textView)
    }

    private func focusTerminal() {
        surface.hostedView.ensureFocus(for: surface.tabId, surfaceId: surface.id)
    }

    private func forwardText(_ text: String, focusTerminalAfterSend: Bool) {
        surface.sendInput(text)
        if focusTerminalAfterSend {
            focusTerminal()
        }
    }

    private func forwardKey(_ key: TextBoxTerminalKey) {
        _ = surface.sendNamedKey(key.rawValue)
    }

    private func forwardControl(_ key: String) {
        _ = surface.sendNamedKey("ctrl-\(key)")
    }

    private func handlePaste(_ pasteboard: NSPasteboard, into textView: TextBoxInputTextView) -> Bool {
        let preparedContent = TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste
        )
        return insertPreparedContent(preparedContent, into: textView)
    }

    private func insertPreparedContent(
        _ preparedContent: TerminalImageTransferPreparedContent,
        into textView: TextBoxInputTextView
    ) -> Bool {
        switch preparedContent {
        case .insertText(let insertedText):
            insertText(insertedText, into: textView)
            return true
        case .fileURLs(let fileURLs):
            return attachFileURLs(fileURLs, into: textView)
        case .reject:
            return false
        }
    }

    private func attachFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return false }

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: standardizedURLs,
            target: surface.resolvedImageTransferTarget(),
            mode: .paste
        )

        switch plan {
        case .insertText, .insertTextSegments:
            textView.insertAttachments(
                standardizedURLs.map {
                        TextBoxAttachment(
                            localURL: $0,
                            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0),
                            cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed($0)
                        )
                }
            )
            attachments = textView.inlineAttachments()
            text = textView.plainText()
            return true
        case .uploadFiles(let uploadURLs, let remoteTarget):
            uploadFileAttachments(uploadURLs, remoteTarget: remoteTarget, focusing: textView)
            return true
        case .reject:
            return false
        }
    }

    private func uploadFileAttachments(
        _ fileURLs: [URL],
        remoteTarget: TerminalRemoteUploadTarget,
        focusing textView: TextBoxInputTextView
    ) {
        let placeholderID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: placeholderID)
        let operation = TerminalImageTransferOperation()
        let uploadValidationToken = textView.pendingAttachmentUploadValidationToken()
        surface.hostedView.beginImageTransferIndicator(
            for: operation,
            onCancel: { _ = operation.cancel() }
        )

        let finish: (Result<[String], Error>) -> Void = { [weak surface] result in
            DispatchQueue.main.async {
                @MainActor func removePendingPlaceholder() {
                    guard textViewReference.textView === textView,
                          textView.removePendingAttachmentUploadPlaceholder(id: placeholderID) else {
                        return
                    }
                    attachments = textView.inlineAttachments()
                    text = textView.plainText()
                }

                surface?.hostedView.endImageTransferIndicator(for: operation)
                guard operation.finish() else {
                    removePendingPlaceholder()
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    return
                }

                switch result {
                case .success(let remotePaths):
                    guard !remotePaths.isEmpty else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        NSSound.beep()
                        return
                    }
                    let newAttachments = fileURLs.enumerated().compactMap { index, fileURL -> TextBoxAttachment? in
                        guard remotePaths.indices.contains(index) else { return nil }
                        return TextBoxAttachment(
                            localURL: fileURL,
                            submissionText: TextBoxAttachment.submissionText(forPath: remotePaths[index]),
                            submissionPath: remotePaths[index],
                            cleanupLocalURLWhenDisposed: true
                        )
                    }
                    guard !newAttachments.isEmpty else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        NSSound.beep()
                        return
                    }
                    guard textViewReference.textView === textView,
                          textView.canAcceptPendingAttachmentUpload(validationToken: uploadValidationToken) else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        return
                    }
                    guard textView.replacePendingAttachmentUploadPlaceholder(
                        id: placeholderID,
                        with: newAttachments
                    ) else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        return
                    }
                    attachments = textView.inlineAttachments()
                    text = textView.plainText()
                case .failure:
                    removePendingPlaceholder()
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    NSSound.beep()
                }
            }
        }

        switch remoteTarget {
        case .workspaceRemote:
            guard let workspace = MainActor.assumeIsolated({
                surface.owningWorkspace()
            }) else {
                finish(.failure(NSError(domain: "cmux.textbox.attachment", code: 3)))
                return
            }
            workspace.uploadDroppedFilesForRemoteTerminal(
                fileURLs,
                operation: operation,
                completion: finish
            )
        case .detectedSSH(let session):
            session.uploadDroppedFiles(
                fileURLs,
                operation: operation,
                completion: finish
            )
        }
    }

    private func insertText(_ insertedText: String, into textView: TextBoxInputTextView) {
        textView.window?.makeFirstResponder(textView)
        textView.insertText(insertedText, replacementRange: textView.selectedRange())
    }
}

struct TextBoxInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var attachments: [TextBoxAttachment]
    @Binding var textViewHeight: CGFloat
    @Binding var hasPendingAttachmentUpload: Bool
    let font: NSFont
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let terminalTitle: String
    let completionRootDirectory: String?
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onFocusTextBox: () -> Void
    let onToggleFocus: () -> Void
    let onForwardText: (String, Bool) -> Void
    let onForwardKey: (TextBoxTerminalKey) -> Void
    let onForwardControl: (String) -> Void
    let onPaste: (NSPasteboard, TextBoxInputTextView) -> Bool
    let onInsertFileURLs: ([URL], TextBoxInputTextView) -> Bool
    let onChooseFiles: () -> Void
    let onContentChanged: () -> Void
    let onTextViewCreated: (TextBoxInputTextView) -> Void
    let onTextViewMovedToWindow: (TextBoxInputTextView) -> Void
    let onTextViewDismantled: (TextBoxInputTextView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TextBoxInputTextView()
        textView.delegate = context.coordinator
        textView.onMoveToWindow = onTextViewMovedToWindow
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: TextBoxLayout.minimumTextHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 1, height: TextBoxLayout.minimumTextHeight)
        )
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = TextBoxLayout.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        updateTextView(textView, context: context)
        onTextViewCreated(textView)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? TextBoxInputTextView else { return }
        coordinator.parent.onTextViewDismantled(textView)
        textView.onMoveToWindow = { _ in }
        textView.onLayoutCompleted = { _ in }
        textView.invalidatePendingAttachmentUploads()
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TextBoxInputTextView else { return }
        textView.onMoveToWindow = onTextViewMovedToWindow
        let contentSize = scrollView.contentView.bounds.size
        if contentSize.width > 0 {
            textView.frame.size.width = contentSize.width
            textView.textContainer?.containerSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        if textView.inlineAttachments().isEmpty && textView.plainText() != text {
            textView.string = text
        }
        updateTextView(textView, context: context)
    }

    private func updateTextView(_ textView: TextBoxInputTextView, context: Context) {
        let coordinator = context.coordinator
        textView.font = font
        textView.textColor = foregroundColor
        textView.backgroundColor = .clear
        textView.insertionPointColor = foregroundColor
        textView.terminalTitle = terminalTitle
        textView.completionRootDirectory = completionRootDirectory
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onFocusTextBox = onFocusTextBox
        textView.onToggleFocus = onToggleFocus
        textView.onForwardText = onForwardText
        textView.onForwardKey = onForwardKey
        textView.onForwardControl = onForwardControl
        textView.onPaste = onPaste
        textView.onInsertFileURLs = onInsertFileURLs
        textView.onChooseFiles = onChooseFiles
        textView.refreshInlineAttachmentCells(font: font, foregroundColor: foregroundColor)
        textView.recenterSingleLineTextContainer()
        textView.wantsLayer = true
        textView.layer?.backgroundColor = NSColor.clear.cgColor
        textView.layer?.borderWidth = 0
        textView.delegate = context.coordinator
        textView.onLayoutCompleted = { [weak coordinator] textView in
            coordinator?.recalculateHeight(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextBoxInputView

        init(parent: TextBoxInputView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TextBoxInputTextView else { return }
            textView.normalizeTextBaselineOffsets()
            parent.text = textView.plainText()
            parent.attachments = textView.inlineAttachments()
            parent.hasPendingAttachmentUpload = textView.hasPendingAttachmentUploadPlaceholder()
            parent.onContentChanged()
            if parent.text.isEmpty,
               parent.attachments.isEmpty,
               !textView.hasPendingAttachmentUploadPlaceholder() {
                textView.invalidatePendingAttachmentUploads()
            }
            textView.refreshMentionCompletions()
            recalculateHeight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? TextBoxInputTextView else { return }
            let color = textView.textColor ?? .labelColor
            textView.layer?.borderColor = color.withAlphaComponent(
                textView.window?.firstResponder === textView ? 0.45 : 0.24
            ).cgColor
            textView.refreshInlineAttachmentFocus()
            textView.refreshMentionCompletions()
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            (textView as? TextBoxInputTextView)?.recenterSingleLineTextContainer()
            layoutManager.ensureLayout(for: textContainer)
            let lineFragmentCount = (textView as? TextBoxInputTextView)?.visualLineFragmentCount()
                ?? TextBoxInputTextView.visualLineFragmentCount(
                    textView: textView,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
            let preferredHeight: CGFloat

            if lineFragmentCount <= TextBoxLayout.minLines {
                let font = textView.font ?? parent.font
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                preferredHeight = max(
                    TextBoxLayout.minimumTextHeight,
                    lineHeight + TextBoxLayout.textInset.height * 2
                )
            } else {
                let font = textView.font ?? parent.font
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                let lineSpacing = CGFloat(max(0, lineFragmentCount - 1)) * TextBoxLayout.lineSpacing
                let inset = TextBoxLayout.textInset(forLineCount: lineFragmentCount)
                let usedRect = layoutManager.usedRect(for: textContainer)
                preferredHeight = ceil(
                    max(
                        usedRect.height,
                        lineHeight * CGFloat(lineFragmentCount) + lineSpacing
                    ) + inset.height * 2
                )
            }

            if abs(textView.frame.height - preferredHeight) > 0.5 {
                textView.frame.size.height = preferredHeight
            }
            if abs(parent.textViewHeight - preferredHeight) > 0.5 {
                parent.textViewHeight = preferredHeight
            }
        }
    }
}

final class TextBoxInputTextView: NSTextView {
    var terminalTitle = ""
    var completionRootDirectory: String?
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
    private var isReportingLayoutCompletion = false

    private static let localControlKeys: Set<String> = ["a", "e", "f", "b", "n", "p", "k", "h"]
    private static let pendingAttachmentUploadPlaceholderCharacter = "\u{200B}"
    private static let pendingAttachmentUploadPlaceholderAttribute = NSAttributedString.Key(
        "cmux.textBoxPendingAttachmentUploadID"
    )
    private var attachmentPreviewPopover: NSPopover?
    private var attachmentPreviewCharacterIndex: Int?
    private var focusedAttachmentCharacterIndex: Int?
    private var attachmentKeyDownMonitor: Any?
    private var preserveAttachmentFocusOnNextResign = false
    private var attachmentUploadInvalidationGeneration: UInt64 = 0
    private var mentionCompletionPopover: NSPopover?
    private var mentionCompletionControllerStorage: TextBoxMentionCompletionController?
    private var pendingUndoableAttachmentFileCleanup: [String: TextBoxAttachment] = [:]
    private var pendingAutomaticAttachmentFileCleanup: [String: TextBoxAttachment] = [:]
    private var suppressAutomaticAttachmentFileCleanup = false
    private var mentionCompletionController: TextBoxMentionCompletionController {
        if let mentionCompletionControllerStorage {
            return mentionCompletionControllerStorage
        }
        let controller = TextBoxMentionCompletionController()
        controller.onStateChanged = { [weak self] in
            self?.syncMentionCompletionPopover()
        }
        mentionCompletionControllerStorage = controller
        return controller
    }

    private var isAttachmentPreviewShown: Bool {
        attachmentPreviewPopover?.isShown == true
    }

    deinit {
        dismissMentionCompletions()
        removeAttachmentKeyDownMonitor()
        discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidatePendingAttachmentUploads()
        } else {
            notifyMovedToWindowIfAttached()
        }
        layer?.borderColor = textColor?.withAlphaComponent(0.24).cgColor
    }

    private func notifyMovedToWindowIfAttached() {
        guard window != nil else { return }
        onMoveToWindow(self)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusTextBox()
            layer?.borderColor = textColor?.withAlphaComponent(0.45).cgColor
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            dismissMentionCompletions()
            layer?.borderColor = textColor?.withAlphaComponent(0.24).cgColor
            if preserveAttachmentFocusOnNextResign,
               isAttachmentPreviewShown,
               focusedAttachmentCharacterIndex != nil {
                preserveAttachmentFocusOnNextResign = false
                installAttachmentKeyDownMonitorIfNeeded()
            } else if !isAttachmentPreviewShown {
                preserveAttachmentFocusOnNextResign = false
                clearAttachmentFocus(dismissPreview: true)
                refreshInlineAttachmentFocus()
            } else {
                preserveAttachmentFocusOnNextResign = false
            }
        }
        return result
    }

    override func paste(_ sender: Any?) {
        if onPaste(.general, self) {
            refreshInlineAttachmentFocus()
            return
        }
        super.paste(sender)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
            return false
        }
        queueAutomaticAttachmentFileCleanup(in: affectedCharRange)
        return true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        queueAutomaticAttachmentFileCleanup(in: replacementRange)
        super.insertText(insertString, replacementRange: replacementRange)
        flushAutomaticAttachmentFileCleanup()
    }

    override func didChangeText() {
        super.didChangeText()
        flushAutomaticAttachmentFileCleanup()
    }

    override func copy(_ sender: Any?) {
        if copySelectedAttachments(to: .general) {
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard let payload = selectedAttachmentEditingPayload(),
              writeAttachments(payload.attachments, to: .general) else {
            super.cut(sender)
            return
        }
        deleteAttachmentSelection(in: payload.range, cleanupAttachmentFiles: false)
    }

    func openFilePicker() {
        onChooseFiles()
    }

    func clearContent(cleanupAttachmentFiles: Bool = true) {
        if cleanupAttachmentFiles {
            cleanupDisposableAttachmentFiles(
                inlineAttachments(),
                preservingActiveInlineAttachments: false
            )
        }
        invalidatePendingAttachmentUploads()
        dismissMentionCompletions()
        clearAttachmentFocus(dismissPreview: true)
        textStorage?.setAttributedString(NSAttributedString(string: ""))
        recenterSingleLineTextContainer()
        didChangeText()
    }

    func prepareForSubmit() {
        flushAutomaticAttachmentFileCleanup()
        discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    func installPreservedContent(_ content: NSAttributedString) {
        installAttributedContent(content)
    }

    func installSessionDraft(_ draft: SessionTextBoxInputDraftSnapshot) {
        installAttributedContent(attributedContent(from: draft))
    }

    private func installAttributedContent(_ content: NSAttributedString) {
        invalidatePendingAttachmentUploads()
        dismissMentionCompletions()
        clearAttachmentFocus(dismissPreview: true)
        textStorage?.setAttributedString(content)
        refreshInlineAttachmentCells(
            font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
        typingAttributes = currentTextAttributes()
        setSelectedRange(NSRange(location: attributedString().length, length: 0))
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        recenterSingleLineTextContainer()
        didChangeText()
    }

    func attributedContentForPreservation() -> NSAttributedString {
        let preserved = NSMutableAttributedString(attributedString: attributedString())
        Self.removePendingAttachmentUploadPlaceholders(from: preserved)
        return preserved
    }

    func sessionDraftSnapshot(isActive: Bool) -> SessionTextBoxInputDraftSnapshot? {
        Self.sessionDraftSnapshot(from: attributedContentForPreservation(), isActive: isActive)
    }

    static func sessionDraftSnapshot(
        from attributed: NSAttributedString,
        isActive: Bool
    ) -> SessionTextBoxInputDraftSnapshot? {
        sessionDraftSnapshot(
            parts: TextBoxSubmissionFormatter.parts(from: attributed),
            isActive: isActive
        )
    }

    static func sessionDraftSnapshot(
        text: String,
        attachments: [TextBoxAttachment],
        isActive: Bool
    ) -> SessionTextBoxInputDraftSnapshot? {
        var parts: [TextBoxSubmissionPart] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        parts.append(contentsOf: attachments.map { .attachment($0) })
        return sessionDraftSnapshot(parts: parts, isActive: isActive)
    }

    static func plainText(from draft: SessionTextBoxInputDraftSnapshot) -> String {
        draft.parts.compactMap { part -> String? in
            guard part.kind == .text else { return nil }
            return part.text
        }.joined()
    }

    static func attachments(from draft: SessionTextBoxInputDraftSnapshot) -> [TextBoxAttachment] {
        draft.parts.compactMap { part -> TextBoxAttachment? in
            guard part.kind == .attachment,
                  let attachment = part.attachment else { return nil }
            return attachment.textBoxAttachment()
        }
    }

    private static func sessionDraftSnapshot(
        parts: [TextBoxSubmissionPart],
        isActive: Bool
    ) -> SessionTextBoxInputDraftSnapshot? {
        let draftParts = parts.compactMap { part -> SessionTextBoxInputDraftPart? in
            switch part {
            case .text(let text):
                guard !text.isEmpty else { return nil }
                return .text(text)
            case .attachment(let attachment):
                return .attachment(SessionTextBoxInputAttachmentSnapshot(attachment))
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

    private func attributedContent(from draft: SessionTextBoxInputDraftSnapshot) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for part in draft.parts {
            switch part.kind {
            case .text:
                guard let text = part.text,
                      !text.isEmpty else { continue }
                attributed.append(NSAttributedString(string: text, attributes: currentTextAttributes()))
            case .attachment:
                guard let attachment = part.attachment?.textBoxAttachment() else { continue }
                attributed.append(inlineAttachmentAttributedString(for: attachment))
            }
        }
        return attributed
    }

    func insertAttachments(_ attachments: [TextBoxAttachment]) {
        guard !attachments.isEmpty else { return }
        window?.makeFirstResponder(self)

        insertAttachments(attachments, replacementRange: selectedRange())
    }

    func insertPendingAttachmentUploadPlaceholder(id: UUID) {
        window?.makeFirstResponder(self)
        var attributes = currentTextAttributes()
        attributes[Self.pendingAttachmentUploadPlaceholderAttribute] = id.uuidString
        insertText(
            NSAttributedString(
                string: Self.pendingAttachmentUploadPlaceholderCharacter,
                attributes: attributes
            ),
            replacementRange: selectedRange()
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
    }

    @discardableResult
    func replacePendingAttachmentUploadPlaceholder(
        id: UUID,
        with attachments: [TextBoxAttachment]
    ) -> Bool {
        guard !attachments.isEmpty,
              let textStorage,
              let placeholderRange = pendingAttachmentUploadPlaceholderRange(id: id) else {
            return false
        }

        attachments.forEach(TextBoxDraftAttachmentStorage.prepareDurableCopy)
        let selectedRangeBeforeReplacement = selectedRange()
        let inserted = inlineAttachmentAttributedString(for: attachments, replacing: placeholderRange)
        textStorage.replaceCharacters(in: placeholderRange, with: inserted)
        setSelectedRange(
            adjustedSelectionRange(
                selectedRangeBeforeReplacement,
                replacing: placeholderRange,
                insertedLength: inserted.length
            )
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        return true
    }

    @discardableResult
    func removePendingAttachmentUploadPlaceholder(id: UUID) -> Bool {
        guard let textStorage,
              let placeholderRange = pendingAttachmentUploadPlaceholderRange(id: id) else {
            return false
        }

        let selectedRangeBeforeRemoval = selectedRange()
        textStorage.replaceCharacters(in: placeholderRange, with: NSAttributedString(string: ""))
        setSelectedRange(
            adjustedSelectionRange(
                selectedRangeBeforeRemoval,
                replacing: placeholderRange,
                insertedLength: 0
            )
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        return true
    }

    func hasPendingAttachmentUploadPlaceholder() -> Bool {
        pendingAttachmentUploadPlaceholderRange(id: nil) != nil
    }

    private func insertAttachments(
        _ attachments: [TextBoxAttachment],
        replacementRange: NSRange
    ) {
        guard !attachments.isEmpty else { return }
        attachments.forEach(TextBoxDraftAttachmentStorage.prepareDurableCopy)
        let inserted = NSMutableAttributedString()
        inserted.append(inlineAttachmentAttributedString(for: attachments, replacing: replacementRange))
        insertText(inserted, replacementRange: replacementRange)
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
    }

    func plainText() -> String {
        stringByStrippingNonTextMarkers(from: attributedString().string)
    }

    func inlineAttachments() -> [TextBoxAttachment] {
        var result: [TextBoxAttachment] = []
        attributedString().enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString().length),
            options: []
        ) { value, _, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            result.append(attachment.textBoxAttachment)
        }
        return result
    }

    func submissionText() -> String {
        TextBoxSubmissionFormatter.formattedText(from: attributedString())
    }

    func submissionParts() -> [TextBoxSubmissionPart] {
        TextBoxSubmissionFormatter.parts(from: attributedString())
    }

    func hasSubmittableContent() -> Bool {
        TextBoxSubmissionFormatter.hasSubmittableContent(submissionParts())
    }

    func refreshInlineAttachmentCells(font: NSFont, foregroundColor: NSColor) {
        let attributed = attributedString()
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            attachment.refreshCell(
                font: font,
                foregroundColor: foregroundColor,
                isFocused: isAttachmentFocused(at: range.location)
            )
        }
        normalizeTextBaselineOffsets()
        typingAttributes = currentTextAttributes(font: font, foregroundColor: foregroundColor)
        recenterSingleLineTextContainer()
    }

    func refreshInlineAttachmentFocus() {
        if !isFocusedAttachmentSelectionValid() {
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
        }
        refreshInlineAttachmentCells(
            font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
    }

    func recenterSingleLineTextContainer() {
        guard let layoutManager,
              let textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let lineFragmentCount = visualLineFragmentCount()

        let targetHeight = bounds.height > 0 ? bounds.height : TextBoxLayout.minimumTextHeight
        var targetVerticalInset: CGFloat
        if lineFragmentCount <= TextBoxLayout.minLines {
            let currentFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
            let singleLineHeight = max(
                TextBoxLayout.minimumTextHeight,
                lineHeight + TextBoxLayout.textInset.height * 2
            )
            let centeredHeight = min(targetHeight, singleLineHeight)
            targetVerticalInset = max(0, (centeredHeight - lineHeight) / 2)
        } else {
            targetVerticalInset = TextBoxLayout.multilineTextInset.height
        }
        if containsInlineTextAttachment() {
            targetVerticalInset = max(
                0,
                targetVerticalInset - TextBoxLayout.inlineAttachmentTextInsetCompensation
            )
        }

        let targetHorizontalInset = TextBoxLayout.textInset(forLineCount: lineFragmentCount).width
        let currentInset = textContainerInset
        guard abs(currentInset.height - targetVerticalInset) > 0.25
            || abs(currentInset.width - targetHorizontalInset) > 0.25 else { return }
        textContainerInset = NSSize(width: targetHorizontalInset, height: targetVerticalInset)
    }

    fileprivate func visualLineFragmentCount() -> Int {
        guard let layoutManager,
              let textContainer else { return 1 }
        return Self.visualLineFragmentCount(
            textView: self,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }

    fileprivate static func visualLineFragmentCount(
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> Int {
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var softLineCount = glyphRange.length == 0 ? 1 : 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            softLineCount += 1
        }
        let explicitLineCount = max(1, (textView.string as NSString).components(separatedBy: "\n").count)
        return max(softLineCount, explicitLineCount)
    }

    override func layout() {
        super.layout()
        recenterSingleLineTextContainer()
        guard !isReportingLayoutCompletion else { return }
        isReportingLayoutCompletion = true
        onLayoutCompleted(self)
        isReportingLayoutCompletion = false
    }

#if DEBUG
    func installDebugInlineFixture(
        _ attachment: TextBoxAttachment?,
        beforeText: String,
        afterText: String
    ) {
        let textAttributes = currentTextAttributes()
        let attributed = NSMutableAttributedString(string: beforeText, attributes: textAttributes)
        if let attachment {
            attributed.append(inlineAttachmentAttributedString(for: attachment))
        }
        attributed.append(NSAttributedString(string: afterText, attributes: textAttributes))

        textStorage?.setAttributedString(attributed)
        normalizeTextBaselineOffsets()
        typingAttributes = currentTextAttributes()
        setSelectedRange(NSRange(location: attributed.length, length: 0))
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        recenterSingleLineTextContainer()
        scrollRangeToVisible(NSRange(location: attributed.length, length: 0))
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
        window?.displayIfNeeded()
        didChangeText()
    }

    @discardableResult
    func debugInteract(action: String) -> [String: Any] {
        window?.makeFirstResponder(self)

        switch action {
        case "focus":
            break
        case "submit":
            submitIfAllowed()
        case "select_first_attachment":
            if let characterIndex = firstInlineAttachmentCharacterIndex() {
                selectAttachment(at: characterIndex)
            }
        case "close_first_attachment":
            if let characterIndex = firstInlineAttachmentCharacterIndex() {
                deleteAttachment(at: characterIndex)
            }
        case "preview_first_attachment":
            if let characterIndex = firstInlineAttachmentCharacterIndex(),
               let attachment = attachment(at: characterIndex) {
                showAttachmentPreview(attachment, characterIndex: characterIndex)
            }
        case "open_preview":
            if let focused = focusedAttachment() {
                TextBoxAttachmentPreviewOpening.openInPreview(focused.attachment)
            }
        case "space":
            if let focused = focusedAttachment() {
                toggleAttachmentPreview(focused.attachment, characterIndex: focused.characterIndex)
            }
        case "left":
            moveInsertionPointLeft()
        case "right":
            moveInsertionPointRight()
        case "escape":
            if isAttachmentPreviewShown {
                dismissAttachmentPreview()
            } else {
                clearAttachmentFocus(dismissPreview: true)
                refreshInlineAttachmentFocus()
            }
        default:
            break
        }

        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
        window?.displayIfNeeded()
        return debugInteractionState()
    }

    func debugInteractionState() -> [String: Any] {
        let selection = selectedRange()
        return [
            "selected_location": selection.location,
            "selected_length": selection.length,
            "focused_attachment_index": focusedAttachmentCharacterIndex ?? -1,
            "preview_shown": isAttachmentPreviewShown,
            "attachment_count": inlineAttachments().count,
            "plain_text": plainText()
        ]
    }

    private func firstInlineAttachmentCharacterIndex() -> Int? {
        var result: Int?
        attributedString().enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString().length),
            options: []
        ) { value, range, stop in
            guard value is TextBoxInlineTextAttachment else { return }
            result = range.location
            stop.pointee = true
        }
        return result
    }
#endif

    override func mouseDown(with event: NSEvent) {
        dismissMentionCompletions()
        if let hit = inlineAttachmentHit(for: event) {
            window?.makeFirstResponder(self)
            if hit.closeRect.contains(hit.point) {
                deleteAttachment(at: hit.characterIndex)
                return
            }
            selectAttachment(at: hit.characterIndex)
            if event.clickCount >= 2 {
                showAttachmentPreview(hit.attachment, characterIndex: hit.characterIndex)
            }
            return
        }
        clearAttachmentFocus(dismissPreview: true)
        super.mouseDown(with: event)
    }

    fileprivate func handleInlineAttachmentCellClick(
        attachment: TextBoxAttachment,
        characterIndex: Int,
        clickCount: Int,
        isCloseClick: Bool
    ) {
        window?.makeFirstResponder(self)
        if isCloseClick {
            deleteAttachment(at: characterIndex)
            return
        }

        selectAttachment(at: characterIndex)
        if clickCount >= 2 {
            showAttachmentPreview(attachment, characterIndex: characterIndex)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: insertionIndex(for: point), length: 0))
        return onInsertFileURLs(urls, self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if handleConfiguredTextBoxShortcut(event) {
            return true
        }
        if handleStandardEditShortcut(event) {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              event.keyCode == UInt16(kVK_ANSI_Z) else {
            return super.performKeyEquivalent(with: event)
        }

        if flags.contains(.shift) {
            guard undoManager?.canRedo == true else { return true }
            undoManager?.redo()
            synchronizeAfterUndoRedo()
            return true
        }

        guard undoManager?.canUndo == true else { return true }
        undoManager?.undo()
        synchronizeAfterUndoRedo()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleConfiguredTextBoxShortcut(event) {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let eventHasMarkedText = hasMarkedText()

        if !eventHasMarkedText,
           handleMentionCompletionKeyEvent(event) {
            return
        }

        if handleFocusedAttachmentKeyEvent(event) {
            return
        }

        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            if eventHasMarkedText {
                super.keyDown(with: event)
                return
            }
            if flags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(self)
            } else {
                submitIfAllowed()
            }
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            if eventHasMarkedText {
                super.keyDown(with: event)
                return
            }
            onEscape()
            return
        }

        if shouldHandleTextBoxPlainArrowLocally(
            keyCode: event.keyCode,
            firstResponderHasMarkedText: eventHasMarkedText,
            flags: flags
        ) {
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                moveInsertionPointLeft()
                return
            case kVK_RightArrow:
                moveInsertionPointRight()
                return
            case kVK_UpArrow:
                super.moveUp(self)
                return
            case kVK_DownArrow:
                super.moveDown(self)
                return
            default:
                break
            }
        }

        if flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           let key = controlKey(for: event) {
            if Self.localControlKeys.contains(key) {
                super.keyDown(with: event)
            } else {
                onForwardControl(key)
            }
            return
        }

        if string.isEmpty,
           !flags.contains(.command),
           !flags.contains(.option),
           let char = event.characters,
           char.count == 1,
           TextBoxAgentDetection.supportsAgentPrefixes(context: terminalTitle) {
            switch char {
            case "?":
                onForwardText(char, false)
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    override func doCommand(by commandSelector: Selector) {
        if hasMarkedText() {
            super.doCommand(by: commandSelector)
            return
        }

        if handleMentionCompletionCommand(commandSelector) {
            return
        }

        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            insertNewlineIgnoringFieldEditor(self)
            return
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitIfAllowed()
            return
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if isAttachmentPreviewShown {
                dismissAttachmentPreview()
                return
            }
            onEscape()
            return
        }

        switch commandSelector {
        case #selector(NSResponder.deleteBackward(_:)):
            if deleteAttachmentForKeyboardCommand(direction: .backward) {
                return
            }
        case #selector(NSResponder.deleteForward(_:)):
            if deleteAttachmentForKeyboardCommand(direction: .forward) {
                return
            }
        case #selector(NSResponder.moveLeft(_:)):
            if moveFocusedAttachmentSelection(toTrailingEdge: false) {
                return
            }
            moveInsertionPointLeft()
            return
        case #selector(NSResponder.moveRight(_:)):
            if moveFocusedAttachmentSelection(toTrailingEdge: true) {
                return
            }
            moveInsertionPointRight()
            return
        case #selector(NSResponder.moveBackward(_:)):
            moveInsertionPointLeft()
            return
        case #selector(NSResponder.moveForward(_:)):
            moveInsertionPointRight()
            return
        case #selector(NSResponder.moveUp(_:)):
            super.moveUp(self)
            return
        case #selector(NSResponder.moveDown(_:)):
            super.moveDown(self)
            return
        default:
            break
        }

        if string.isEmpty {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                onForwardKey(.tab)
                return
            case #selector(NSResponder.deleteBackward(_:)):
                onForwardKey(.backspace)
                return
            default:
                break
            }
        }

        super.doCommand(by: commandSelector)
    }

    func refreshMentionCompletions() {
        mentionCompletionController.refresh(
            for: TextBoxMentionCompletionDetector.query(
                in: attributedString().string,
                selectedRange: selectedRange()
            ),
            rootDirectory: completionRootDirectory
        )
    }

    private func handleMentionCompletionKeyEvent(_ event: NSEvent) -> Bool {
        guard mentionCompletionController.hasSuggestions else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option) else {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            mentionCompletionController.moveSelection(delta: -1)
            return true
        case kVK_DownArrow:
            mentionCompletionController.moveSelection(delta: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !flags.contains(.shift) else { return false }
            return acceptMentionCompletion()
        case kVK_Tab:
            return acceptMentionCompletion()
        case kVK_Escape:
            dismissMentionCompletions()
            return true
        default:
            return false
        }
    }

    private func handleMentionCompletionCommand(_ commandSelector: Selector) -> Bool {
        guard mentionCompletionController.hasSuggestions else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            mentionCompletionController.moveSelection(delta: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            mentionCompletionController.moveSelection(delta: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)):
            return acceptMentionCompletion()
        case #selector(NSResponder.cancelOperation(_:)):
            dismissMentionCompletions()
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func acceptMentionCompletion(_ explicitSuggestion: TextBoxMentionSuggestion? = nil) -> Bool {
        guard let query = mentionCompletionController.activeQuery,
              let suggestion = explicitSuggestion ?? mentionCompletionController.selectedSuggestion,
              isValidSelectedRange(query.range),
              shouldChangeText(in: query.range, replacementString: suggestion.insertionText) else {
            return false
        }

        let replacement = mentionCompletionReplacementText(
            for: suggestion,
            replacing: query.range
        )
        textStorage?.replaceCharacters(
            in: query.range,
            with: NSAttributedString(string: replacement, attributes: currentTextAttributes())
        )
        let insertionLocation = query.location + (replacement as NSString).length
        setSelectedRange(NSRange(location: insertionLocation, length: 0))
        dismissMentionCompletions()
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        scrollRangeToVisible(NSRange(location: insertionLocation, length: 0))
        return true
    }

    private func mentionCompletionReplacementText(
        for suggestion: TextBoxMentionSuggestion,
        replacing range: NSRange
    ) -> String {
        let nsText = attributedString().string as NSString
        let nextLocation = NSMaxRange(range)
        guard nextLocation < nsText.length else {
            return suggestion.insertionText + " "
        }

        let nextCharacter = nsText.substring(with: NSRange(location: nextLocation, length: 1))
        if nextCharacter.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return suggestion.insertionText
        }
        return suggestion.insertionText + " "
    }

    private func syncMentionCompletionPopover() {
        guard mentionCompletionController.hasSuggestions,
              window?.firstResponder === self,
              let anchorRect = mentionCompletionAnchorRect() else {
            dismissMentionCompletionPopoverOnly()
            return
        }

        let popover = mentionCompletionPopover ?? makeMentionCompletionPopover()
        popover.contentSize = NSSize(
            width: 430,
            height: CGFloat(mentionCompletionController.suggestions.count) * 36 + 10
        )
        if !popover.isShown {
            popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
            window?.makeFirstResponder(self)
        }
    }

    private func makeMentionCompletionPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: TextBoxMentionCompletionPopoverView(
                controller: mentionCompletionController,
                onSelect: { [weak self] suggestion in
                    self?.window?.makeFirstResponder(self)
                    self?.acceptMentionCompletion(suggestion)
                }
            )
        )
        mentionCompletionPopover = popover
        return popover
    }

    private func mentionCompletionAnchorRect() -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let length = attributedString().length
        guard length > 0 else {
            return NSRect(
                x: textContainerOrigin.x,
                y: textContainerOrigin.y,
                width: 1,
                height: font?.pointSize ?? 14
            )
        }

        let cursor = min(max(0, selectedRange().location), length)
        let characterLocation = max(0, min(cursor, length - 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterLocation, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if cursor > characterLocation {
            rect.origin.x = rect.maxX
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = 1
        rect.size.height = max(rect.height, font?.pointSize ?? 14)
        return rect
    }

    private func dismissMentionCompletions() {
        mentionCompletionControllerStorage?.clear()
        dismissMentionCompletionPopoverOnly()
    }

    private func dismissMentionCompletionPopoverOnly() {
        mentionCompletionPopover?.performClose(nil)
        mentionCompletionPopover = nil
    }

    private func moveInsertionPointLeft() {
        if moveFocusedAttachmentSelection(toTrailingEdge: false) {
            return
        }

        let range = selectedRange()
        if range.length > 0 {
            setSelectedRange(NSRange(location: range.location, length: 0))
            clearAttachmentFocus(dismissPreview: true)
            refreshInlineAttachmentFocus()
            return
        }
        let nextLocation = composedCharacterLocationBefore(range.location)
        guard nextLocation < range.location else { return }
        setSelectedRange(NSRange(location: nextLocation, length: 0))
        clearAttachmentFocus(dismissPreview: true)
        refreshInlineAttachmentFocus()
    }

    func pendingAttachmentUploadValidationToken() -> UInt64 {
        attachmentUploadInvalidationGeneration
    }

    func canAcceptPendingAttachmentUpload(validationToken: UInt64) -> Bool {
        attachmentUploadInvalidationGeneration == validationToken && window != nil
    }

    func invalidatePendingAttachmentUploads() {
        attachmentUploadInvalidationGeneration &+= 1
    }

    private func submitIfAllowed() {
        guard !hasPendingAttachmentUploadPlaceholder() else {
            NSSound.beep()
            return
        }
        guard hasSubmittableContent() else {
            NSSound.beep()
            return
        }
        onSubmit()
    }

    private func synchronizeAfterUndoRedo() {
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        refreshMentionCompletions()
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
    }

#if DEBUG
    func debugSetMentionCompletionState(
        query: TextBoxMentionQuery?,
        suggestions: [TextBoxMentionSuggestion]
    ) {
        mentionCompletionController.debugSetState(query: query, suggestions: suggestions)
    }

    func debugMentionSuggestionCount() -> Int {
        mentionCompletionController.debugSuggestionCount
    }
#endif

    private func handleConfiguredTextBoxShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !KeyboardShortcutRecorderActivity.isAnyRecorderActive else {
            return false
        }
        if KeyboardShortcutSettings.shortcut(for: .focusTextBoxInput).matches(event: event) {
            onToggleFocus()
            return true
        }
        if KeyboardShortcutSettings.shortcut(for: .attachTextBoxFile).matches(event: event) {
            onChooseFiles()
            return true
        }
        return false
    }

    private func handleStandardEditShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }

        switch Int(event.keyCode) {
        case kVK_ANSI_C:
            copy(nil)
            return true
        case kVK_ANSI_X:
            cut(nil)
            return true
        case kVK_ANSI_V:
            paste(nil)
            return true
        default:
            return false
        }
    }

    private func deleteAttachment(at characterIndex: Int) {
        deleteAttachmentSelection(in: NSRange(location: characterIndex, length: 1))
    }

    private enum KeyboardDeleteDirection {
        case backward
        case forward
    }

    private func deleteAttachmentForKeyboardCommand(direction: KeyboardDeleteDirection) -> Bool {
        let range = selectedRange()
        if range.length > 0 {
            guard !inlineAttachments(in: range).isEmpty else {
                return false
            }
            deleteAttachmentSelection(in: range)
            return true
        }

        let attachmentLocation: Int?
        switch direction {
        case .backward:
            attachmentLocation = range.location > 0 ? range.location - 1 : nil
        case .forward:
            attachmentLocation = range.location < attributedString().length ? range.location : nil
        }

        guard let attachmentLocation,
              attachment(at: attachmentLocation) != nil else {
            return false
        }
        deleteAttachmentSelection(in: NSRange(location: attachmentLocation, length: 1))
        return true
    }

    private func moveInsertionPointRight() {
        if moveFocusedAttachmentSelection(toTrailingEdge: true) {
            return
        }

        let range = selectedRange()
        if range.length > 0 {
            setSelectedRange(NSRange(location: range.location + range.length, length: 0))
            clearAttachmentFocus(dismissPreview: true)
            refreshInlineAttachmentFocus()
            return
        }
        let nextLocation = composedCharacterLocationAfter(range.location)
        guard nextLocation > range.location else { return }
        setSelectedRange(NSRange(location: nextLocation, length: 0))
        clearAttachmentFocus(dismissPreview: true)
        refreshInlineAttachmentFocus()
    }

    private func composedCharacterLocationBefore(_ location: Int) -> Int {
        let nsText = string as NSString
        let clampedLocation = min(max(location, 0), nsText.length)
        guard clampedLocation > 0 else { return clampedLocation }
        return nsText.rangeOfComposedCharacterSequence(at: clampedLocation - 1).location
    }

    private func composedCharacterLocationAfter(_ location: Int) -> Int {
        let nsText = string as NSString
        let clampedLocation = min(max(location, 0), nsText.length)
        guard clampedLocation < nsText.length else { return clampedLocation }
        return NSMaxRange(nsText.rangeOfComposedCharacterSequence(at: clampedLocation))
    }

    private func selectAttachment(at characterIndex: Int) {
        guard attachment(at: characterIndex) != nil else {
            clearAttachmentFocus(dismissPreview: true)
            return
        }
        attachmentPreviewCharacterIndex = characterIndex
        focusedAttachmentCharacterIndex = characterIndex
        setSelectedRange(NSRange(location: characterIndex, length: 1))
        scrollRangeToVisible(NSRange(location: characterIndex, length: 1))
        installAttachmentKeyDownMonitorIfNeeded()
        refreshInlineAttachmentFocus()
    }

    private func focusedAttachment() -> (attachment: TextBoxAttachment, characterIndex: Int)? {
        let range = selectedRange()
        if let focusedAttachmentCharacterIndex,
           range.location == focusedAttachmentCharacterIndex,
           range.length == 1,
           let attachment = attachment(at: focusedAttachmentCharacterIndex) {
            return (attachment, focusedAttachmentCharacterIndex)
        }
        if focusedAttachmentCharacterIndex != nil {
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
        }

        if range.length == 1,
           let attachment = attachment(at: range.location) {
            focusedAttachmentCharacterIndex = range.location
            installAttachmentKeyDownMonitorIfNeeded()
            return (attachment, range.location)
        }

        return nil
    }

    private func isAttachmentFocused(at characterIndex: Int) -> Bool {
        focusedAttachmentCharacterIndex == characterIndex
    }

    private func isFocusedAttachmentSelectionValid() -> Bool {
        guard let focusedAttachmentCharacterIndex else { return false }
        let range = selectedRange()
        guard range.location == focusedAttachmentCharacterIndex,
              range.length == 1 else {
            return false
        }
        return attachment(at: focusedAttachmentCharacterIndex) != nil
    }

    private func attachment(at characterIndex: Int) -> TextBoxAttachment? {
        guard characterIndex >= 0,
              characterIndex < attributedString().length,
              let inlineAttachment = attributedString().attribute(
                .attachment,
                at: characterIndex,
                effectiveRange: nil
              ) as? TextBoxInlineTextAttachment else {
            return nil
        }
        return inlineAttachment.textBoxAttachment
    }

    private func moveFocusedAttachmentSelection(toTrailingEdge: Bool) -> Bool {
        guard let focused = focusedAttachment() else { return false }
        let insertionLocation = focused.characterIndex + (toTrailingEdge ? 1 : 0)
        setSelectedRange(NSRange(location: insertionLocation, length: 0))
        clearAttachmentFocus(dismissPreview: true)
        refreshInlineAttachmentFocus()
        return true
    }

    private func toggleAttachmentPreview(
        _ attachment: TextBoxAttachment,
        characterIndex: Int
    ) {
        if isAttachmentPreviewShown,
           attachmentPreviewCharacterIndex == characterIndex {
            dismissAttachmentPreview()
            return
        }
        showAttachmentPreview(attachment, characterIndex: characterIndex)
    }

    private func handleFocusedAttachmentKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let focused = focusedAttachment() else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_Space:
            toggleAttachmentPreview(focused.attachment, characterIndex: focused.characterIndex)
            return true
        case kVK_LeftArrow:
            _ = moveFocusedAttachmentSelection(toTrailingEdge: false)
            return true
        case kVK_RightArrow:
            _ = moveFocusedAttachmentSelection(toTrailingEdge: true)
            return true
        case kVK_Escape:
            if isAttachmentPreviewShown {
                dismissAttachmentPreview()
                return true
            }
            clearAttachmentFocus(dismissPreview: true)
            refreshInlineAttachmentFocus()
            return true
        default:
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
            refreshInlineAttachmentFocus()
            return false
        }
    }

    private func showAttachmentPreview(
        _ attachment: TextBoxAttachment,
        characterIndex: Int
    ) {
        guard attachment.localURL != nil,
              let attachmentRect = attachmentRect(forCharacterIndex: characterIndex) else {
            NSSound.beep()
            return
        }

        dismissAttachmentPreview()
        selectAttachment(at: characterIndex)
        preserveAttachmentFocusOnNextResign = true

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = TextBoxAttachmentPreviewController(attachment: attachment)
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        attachmentPreviewPopover = popover
        attachmentPreviewCharacterIndex = characterIndex
        popover.show(relativeTo: attachmentRect, of: self, preferredEdge: .maxY)
        window?.makeFirstResponder(self)
        installAttachmentKeyDownMonitorIfNeeded()
    }

    private func dismissAttachmentPreview() {
        attachmentPreviewPopover?.performClose(nil)
        attachmentPreviewPopover = nil
        attachmentPreviewCharacterIndex = nil
    }

    private func clearAttachmentFocus(dismissPreview shouldDismissPreview: Bool) {
        if shouldDismissPreview {
            dismissAttachmentPreview()
        }
        focusedAttachmentCharacterIndex = nil
        removeAttachmentKeyDownMonitor()
    }

    private func copySelectedAttachments(to pasteboard: NSPasteboard) -> Bool {
        guard let payload = selectedAttachmentEditingPayload() else { return false }
        return writeAttachments(payload.attachments, to: pasteboard)
    }

    private func selectedAttachmentEditingPayload() -> (attachments: [TextBoxAttachment], range: NSRange)? {
        if let focused = focusedAttachment() {
            return ([focused.attachment], NSRange(location: focused.characterIndex, length: 1))
        }

        let range = selectedRange()
        guard isValidSelectedRange(range), range.length > 0 else { return nil }

        let attributed = attributedString()
        let raw = attributed.string as NSString
        var attachments: [TextBoxAttachment] = []
        var nonAttachmentContent = ""
        attributed.enumerateAttribute(.attachment, in: range, options: []) { value, subrange, _ in
            if let inlineAttachment = value as? TextBoxInlineTextAttachment {
                attachments.append(inlineAttachment.textBoxAttachment)
            } else {
                nonAttachmentContent += raw.substring(with: subrange)
            }
        }

        guard !attachments.isEmpty,
              nonAttachmentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (attachments, range)
    }

    private func isValidSelectedRange(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0 else {
            return false
        }
        return NSMaxRange(range) <= attributedString().length
    }

    private func writeAttachments(
        _ attachments: [TextBoxAttachment],
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard !attachments.isEmpty else { return false }

        let fileURLs = attachments.compactMap(\.localURL)
        let submissionText = attachments
            .map(\.submissionText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var types: [NSPasteboard.PasteboardType] = [.string]
        if !fileURLs.isEmpty {
            types.append(.fileURL)
            types.append(PasteboardFileURLReader.legacyFilenamesPboardType)
        }

        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)

        var wroteContent = false
        if !fileURLs.isEmpty {
            if let firstURL = fileURLs.first {
                wroteContent = pasteboard.setString(firstURL.absoluteString, forType: .fileURL) || wroteContent
            }
            wroteContent = pasteboard.setPropertyList(
                fileURLs.map(\.path),
                forType: PasteboardFileURLReader.legacyFilenamesPboardType
            ) || wroteContent
        }

        if !submissionText.isEmpty {
            wroteContent = pasteboard.setString(submissionText, forType: .string) || wroteContent
        } else if let firstURL = fileURLs.first {
            wroteContent = pasteboard.setString(firstURL.path, forType: .string) || wroteContent
        }
        return wroteContent
    }

    private func deleteAttachmentSelection(
        in range: NSRange,
        cleanupAttachmentFiles: Bool = true
    ) {
        guard isValidSelectedRange(range),
              range.length > 0 else {
            return
        }

        let removedAttachments = inlineAttachments(in: range)
        suppressAutomaticAttachmentFileCleanup = true
        defer { suppressAutomaticAttachmentFileCleanup = false }
        insertText("", replacementRange: range)
        if cleanupAttachmentFiles {
            cleanupRemovedAttachmentFiles(removedAttachments)
        } else {
            removePendingAttachmentCleanup(for: removedAttachments)
        }
        clearAttachmentFocus(dismissPreview: true)
        setSelectedRange(NSRange(location: min(range.location, (string as NSString).length), length: 0))
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
    }

    private func inlineAttachments(in range: NSRange) -> [TextBoxAttachment] {
        guard isValidSelectedRange(range),
              range.length > 0 else {
            return []
        }
        var result: [TextBoxAttachment] = []
        attributedString().enumerateAttribute(.attachment, in: range, options: []) { value, _, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            result.append(attachment.textBoxAttachment)
        }
        return result
    }

    private func queueAutomaticAttachmentFileCleanup(in range: NSRange) {
        guard !suppressAutomaticAttachmentFileCleanup else { return }
        let removedAttachments = inlineAttachments(in: range)
        guard !removedAttachments.isEmpty else { return }
        for attachment in removedAttachments {
            guard attachment.cleanupLocalURLWhenDisposed,
                  let localURL = attachment.localURL else { continue }
            pendingAutomaticAttachmentFileCleanup[Self.attachmentCleanupKey(for: localURL)] = attachment
        }
    }

    private func flushAutomaticAttachmentFileCleanup() {
        guard !pendingAutomaticAttachmentFileCleanup.isEmpty else { return }
        let attachments = Array(pendingAutomaticAttachmentFileCleanup.values)
        pendingAutomaticAttachmentFileCleanup.removeAll(keepingCapacity: true)
        cleanupRemovedAttachmentFiles(attachments)
    }

    private func installAttachmentKeyDownMonitorIfNeeded() {
        guard attachmentKeyDownMonitor == nil else { return }
        attachmentKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.shouldHandleAttachmentMonitorEvent(event) else { return event }
            return self.handleFocusedAttachmentKeyEvent(event) ? nil : event
        }
    }

    private func removeAttachmentKeyDownMonitor() {
        if let attachmentKeyDownMonitor {
            NSEvent.removeMonitor(attachmentKeyDownMonitor)
            self.attachmentKeyDownMonitor = nil
        }
    }

    private func shouldHandleAttachmentMonitorEvent(_ event: NSEvent) -> Bool {
        guard focusedAttachmentCharacterIndex != nil else { return false }
        if event.window === window {
            return true
        }
        if event.window === attachmentPreviewPopover?.contentViewController?.view.window {
            return true
        }
        return false
    }

    private struct InlineAttachmentHit {
        let attachment: TextBoxAttachment
        let characterIndex: Int
        let point: NSPoint
        let closeRect: NSRect
    }

    private static let attachmentReplacementCharacter = "\u{FFFC}"

    private func currentTextAttributes(
        font explicitFont: NSFont? = nil,
        foregroundColor explicitForegroundColor: NSColor? = nil
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: explicitFont ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: explicitForegroundColor ?? textColor ?? .labelColor,
            .baselineOffset: textBaselineOffsetForCurrentContent()
        ]
    }

    private func inlineAttachmentAttributedString(for attachment: TextBoxAttachment) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attachment: TextBoxInlineTextAttachment(
                attachment: attachment,
                font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                foregroundColor: textColor ?? .labelColor
            )
        )
        attributed.addAttribute(
            .baselineOffset,
            value: TextBoxLayout.textBaselineOffset,
            range: NSRange(location: 0, length: attributed.length)
        )
        return attributed
    }

    private func inlineAttachmentAttributedString(for attachments: [TextBoxAttachment]) -> NSAttributedString {
        let inserted = NSMutableAttributedString()
        for (index, attachment) in attachments.enumerated() {
            if index > 0 {
                inserted.append(NSAttributedString(string: " ", attributes: currentTextAttributes()))
            }
            inserted.append(inlineAttachmentAttributedString(for: attachment))
        }
        return inserted
    }

    private func inlineAttachmentAttributedString(
        for attachments: [TextBoxAttachment],
        replacing range: NSRange
    ) -> NSAttributedString {
        let inserted = NSMutableAttributedString()
        if shouldInsertAttachmentBoundarySpaceBefore(replacementRange: range) {
            inserted.append(NSAttributedString(string: " ", attributes: currentTextAttributes()))
        }
        inserted.append(inlineAttachmentAttributedString(for: attachments))
        if shouldInsertAttachmentBoundarySpaceAfter(
            replacementRange: range,
            attachments: attachments
        ) {
            inserted.append(NSAttributedString(string: " ", attributes: currentTextAttributes()))
        }
        return inserted
    }

    private func shouldInsertAttachmentBoundarySpaceBefore(replacementRange: NSRange) -> Bool {
        guard replacementRange.location > 0,
              replacementRange.location <= attributedString().length else {
            return false
        }
        return !isAttachmentBoundarySeparator(at: replacementRange.location - 1)
    }

    private func shouldInsertAttachmentBoundarySpaceAfter(
        replacementRange: NSRange,
        attachments: [TextBoxAttachment]
    ) -> Bool {
        guard attachments.contains(where: \.isImage) else {
            return false
        }
        let afterLocation = NSMaxRange(replacementRange)
        guard afterLocation >= 0,
              afterLocation < attributedString().length else {
            return true
        }
        return !isAttachmentBoundarySeparator(at: afterLocation)
    }

    private func isAttachmentBoundarySeparator(at location: Int) -> Bool {
        guard location >= 0,
              location < attributedString().length else {
            return true
        }
        let character = (attributedString().string as NSString).substring(with: NSRange(location: location, length: 1))
        return character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func pendingAttachmentUploadPlaceholderRanges(
        in attributed: NSAttributedString,
        id: UUID?
    ) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return [] }

        let idString = id?.uuidString
        var result: [NSRange] = []
        attributed.enumerateAttribute(
            Self.pendingAttachmentUploadPlaceholderAttribute,
            in: fullRange,
            options: []
        ) { value, range, stop in
            guard let value = value as? String,
                  idString == nil || value == idString else {
                return
            }
            result.append(range)
            if idString != nil {
                stop.pointee = true
            }
        }
        return result
    }

    private static func removePendingAttachmentUploadPlaceholders(from attributed: NSMutableAttributedString) {
        for range in pendingAttachmentUploadPlaceholderRanges(in: attributed, id: nil).reversed() {
            attributed.replaceCharacters(in: range, with: NSAttributedString(string: ""))
        }
    }

    private func pendingAttachmentUploadPlaceholderRange(id: UUID?) -> NSRange? {
        Self.pendingAttachmentUploadPlaceholderRanges(in: attributedString(), id: id).first
    }

    func cleanupDisposableAttachmentFiles(
        _ attachments: [TextBoxAttachment],
        preservingActiveInlineAttachments: Bool = true
    ) {
        let activeKeys = preservingActiveInlineAttachments ? activeInlineAttachmentCleanupKeys() : []
        var urlsToClean: [URL] = []
        for attachment in attachments {
            guard attachment.cleanupLocalURLWhenDisposed,
                  let url = attachment.localURL else { continue }
            let key = Self.attachmentCleanupKey(for: url)
            pendingUndoableAttachmentFileCleanup.removeValue(forKey: key)
            guard !activeKeys.contains(key) else { continue }
            urlsToClean.append(url)
        }

        let ghosttyTemporaryURLs = urlsToClean.filter { url in
            TextBoxDraftAttachmentStorage.removeCopiedDraftForOriginalTemporaryFile(url)
            return !TextBoxDraftAttachmentStorage.removeIfOwnedDraftCopy(url)
        }
        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(ghosttyTemporaryURLs)
    }

    func cleanupCopiedDraftFilesForPreservedLocalPathSubmissions(_ attachments: [TextBoxAttachment]) {
        for attachment in attachments where attachment.cleanupLocalURLWhenDisposed && attachment.submitsLocalFilePath {
            guard let localURL = attachment.localURL else { continue }
            TextBoxDraftAttachmentStorage.removeCopiedDraftForOriginalTemporaryFile(localURL)
        }
    }

    func cleanupPendingUndoableAttachmentFiles() {
        guard !pendingUndoableAttachmentFileCleanup.isEmpty else { return }
        let activePaths = activeInlineAttachmentCleanupKeys()
        var attachmentsToClean: [TextBoxAttachment] = []
        let cleanupKeys = pendingUndoableAttachmentFileCleanup.keys.filter { !activePaths.contains($0) }
        for key in cleanupKeys {
            if let attachment = pendingUndoableAttachmentFileCleanup.removeValue(forKey: key) {
                attachmentsToClean.append(attachment)
            }
        }
        cleanupDisposableAttachmentFiles(attachmentsToClean)
    }

    func discardUndoHistoryAndCleanupPendingAttachmentFiles() {
        flushAutomaticAttachmentFileCleanup()
        undoManager?.removeAllActions()
        removeActiveAttachmentsFromPendingCleanup()
        cleanupPendingUndoableAttachmentFiles()
    }

    private func removeActiveAttachmentsFromPendingCleanup() {
        guard !pendingUndoableAttachmentFileCleanup.isEmpty else { return }
        for key in activeInlineAttachmentCleanupKeys() {
            pendingUndoableAttachmentFileCleanup.removeValue(forKey: key)
        }
    }

    private func removePendingAttachmentCleanup(for attachments: [TextBoxAttachment]) {
        guard !pendingUndoableAttachmentFileCleanup.isEmpty else { return }
        for attachment in attachments {
            guard let localURL = attachment.localURL else { continue }
            pendingUndoableAttachmentFileCleanup.removeValue(
                forKey: Self.attachmentCleanupKey(for: localURL)
            )
        }
    }

    private func cleanupRemovedAttachmentFiles(_ attachments: [TextBoxAttachment]) {
        guard allowsUndo,
              undoManager?.isUndoRegistrationEnabled == true else {
            cleanupDisposableAttachmentFiles(attachments)
            return
        }
        deferUndoableAttachmentFileCleanup(attachments)
    }

    private func deferUndoableAttachmentFileCleanup(_ attachments: [TextBoxAttachment]) {
        let activePaths = activeInlineAttachmentCleanupKeys()
        for attachment in attachments {
            guard attachment.cleanupLocalURLWhenDisposed,
                  let localURL = attachment.localURL else { continue }
            let key = Self.attachmentCleanupKey(for: localURL)
            guard !activePaths.contains(key) else { continue }
            pendingUndoableAttachmentFileCleanup[key] = attachment
        }
    }

    private func activeInlineAttachmentCleanupKeys() -> Set<String> {
        Set(inlineAttachments().compactMap { attachment in
            attachment.localURL.map(Self.attachmentCleanupKey(for:))
        })
    }

    private static func attachmentCleanupKey(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }

    private func adjustedSelectionRange(
        _ selectedRange: NSRange,
        replacing replacedRange: NSRange,
        insertedLength: Int
    ) -> NSRange {
        guard isValidSelectedRange(selectedRange) else {
            return NSRange(location: NSMaxRange(replacedRange) + insertedLength, length: 0)
        }

        let delta = insertedLength - replacedRange.length
        if selectedRange.location > replacedRange.location {
            return NSRange(
                location: max(0, selectedRange.location + delta),
                length: selectedRange.length
            )
        }
        if NSIntersectionRange(selectedRange, replacedRange).length > 0 {
            return NSRange(location: replacedRange.location + insertedLength, length: 0)
        }
        return selectedRange
    }

    fileprivate static func stringByStrippingNonTextMarkers(from text: String) -> String {
        text
            .replacingOccurrences(of: String(Self.attachmentReplacementCharacter), with: "")
            .replacingOccurrences(of: Self.pendingAttachmentUploadPlaceholderCharacter, with: "")
    }

    private func stringByStrippingNonTextMarkers(from text: String) -> String {
        Self.stringByStrippingNonTextMarkers(from: text)
    }

    func normalizeTextBaselineOffsets() {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else {
            typingAttributes = currentTextAttributes()
            return
        }

        let textOffset = TextBoxLayout.textBaselineOffset

        var updates: [(NSRange, CGFloat)] = []
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            let targetOffset = value == nil ? textOffset : TextBoxLayout.textBaselineOffset
            let currentOffset = Self.baselineOffsetValue(
                textStorage.attribute(.baselineOffset, at: range.location, effectiveRange: nil)
            )
            guard abs(currentOffset - targetOffset) > 0.01 else { return }
            updates.append((range, targetOffset))
        }
        guard !updates.isEmpty else {
            typingAttributes = currentTextAttributes()
            return
        }

        textStorage.beginEditing()
        for (range, targetOffset) in updates {
            textStorage.addAttribute(.baselineOffset, value: targetOffset, range: range)
        }
        textStorage.endEditing()
        typingAttributes = currentTextAttributes()
    }

    private func textBaselineOffsetForCurrentContent() -> CGFloat {
        TextBoxLayout.textBaselineOffset
    }

    private func containsInlineTextAttachment() -> Bool {
        guard let textStorage else { return false }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var foundAttachment = false
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, stop in
            guard value != nil else { return }
            foundAttachment = true
            stop.pointee = true
        }
        return foundAttachment
    }

    private static func baselineOffsetValue(_ value: Any?) -> CGFloat {
        if let value = value as? CGFloat {
            return value
        }
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        return 0
    }

    private func attachmentRect(forCharacterIndex characterIndex: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer,
              characterIndex >= 0,
              characterIndex < attributedString().length,
              attributedString().attribute(
                .attachment,
                at: characterIndex,
                effectiveRange: nil
              ) is TextBoxInlineTextAttachment else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        var attachmentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        attachmentRect.origin.x += textContainerOrigin.x
        attachmentRect.origin.y += textContainerOrigin.y
        return attachmentRect
    }

    private func inlineAttachmentHit(for event: NSEvent) -> InlineAttachmentHit? {
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager,
              let textContainer,
              attributedString().length > 0 else {
            return nil
        }

        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex >= 0,
              characterIndex < attributedString().length,
              let inlineAttachment = attributedString().attribute(
                .attachment,
                at: characterIndex,
                effectiveRange: nil
              ) as? TextBoxInlineTextAttachment else {
            return nil
        }

        guard let attachmentRect = attachmentRect(forCharacterIndex: characterIndex) else {
            return nil
        }
        guard attachmentRect.insetBy(dx: -2, dy: -4).contains(point) else {
            return nil
        }

        return InlineAttachmentHit(
            attachment: inlineAttachment.textBoxAttachment,
            characterIndex: characterIndex,
            point: point,
            closeRect: NSRect(
                x: attachmentRect.maxX - TextBoxLayout.inlineAttachmentTrailingControlWidth - 2,
                y: attachmentRect.minY,
                width: TextBoxLayout.inlineAttachmentTrailingControlWidth + 2,
                height: attachmentRect.height
            )
        )
    }

    private func insertionIndex(for point: NSPoint) -> Int {
        guard let layoutManager,
              let textContainer,
              attributedString().length > 0 else {
            return 0
        }

        var fraction: CGFloat = 0
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return min(attributedString().length, characterIndex + (fraction > 0.5 ? 1 : 0))
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return pasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { object -> URL? in
                if let url = object as? URL { return url }
                if let url = object as? NSURL { return url as URL }
                return nil
            }
            .filter(\.isFileURL) ?? []
    }

    private func controlKey(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        case kVK_ANSI_Backslash: return "\\"
        default:
            return event.charactersIgnoringModifiers?.lowercased()
        }
    }
}
