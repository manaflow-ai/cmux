import CmuxFoundation
import CmuxWorkspaces
import AppKit
import CmuxAppKitSupportUI
import CmuxTerminal
import Carbon.HIToolbox
import Combine
import CmuxSettings
import CmuxSettingsUI
import Observation
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
    static let leadingButtonHorizontalOffset: CGFloat = -2
    static let trailingButtonHorizontalOffset: CGFloat = 2
    static let attachmentControlSpacing: CGFloat = 2
    static var attachmentImageSize: CGFloat {
        GlobalFontMagnification.scaledSize(16)
    }
    static var attachmentChipHeight: CGFloat {
        let font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .semibold)
        return max(18, ceil(font.ascender - font.descender + font.leading) + 6)
    }
    static var inlineAttachmentMaxTextWidth: CGFloat {
        GlobalFontMagnification.scaledSize(118)
    }
    static var inlineAttachmentTrailingControlWidth: CGFloat {
        GlobalFontMagnification.scaledSize(14)
    }

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

@MainActor
private final class TextBoxComposerPillView: NSView {
    let contentView = NSView()
    private let chromeView: NSView

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = TextBoxLayout.pillCornerRadius
            chromeView = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .popover
            visual.blendingMode = .withinWindow
            visual.state = .active
            chromeView = visual
        }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = TextBoxLayout.pillCornerRadius
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.wantsLayer = true
        chromeView.layer?.cornerRadius = TextBoxLayout.pillCornerRadius
        chromeView.layer?.cornerCurve = .continuous
        chromeView.layer?.masksToBounds = true
        chromeView.layer?.borderWidth = 1
        addSubview(chromeView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *), let glass = chromeView as? NSGlassEffectView {
            glass.contentView = contentView
        } else {
            chromeView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: chromeView.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: topAnchor),
            chromeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(foregroundColor: NSColor, backgroundColor: NSColor) {
        chromeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        if let visual = chromeView as? NSVisualEffectView {
            visual.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.20).cgColor
            visual.layer?.borderColor = foregroundColor.withAlphaComponent(0.16).cgColor
        }
    }
}

@MainActor
private final class TextBoxComposerRootView: NSView {
    let composerView = TextBoxComposerPillView()
    var widthPresentation = SessionContentWidthPresentation.disabled {
        didSet { needsLayout = true }
    }
    var contentHeight: CGFloat = TextBoxLayout.minimumTextHeight + 7 {
        didSet {
            guard abs(contentHeight - oldValue) > 0.5 else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        composerView.autoresizingMask = []
        addSubview(composerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let horizontalInset: CGFloat = 10
        let bottomInset: CGFloat = 7
        let availableBounds = bounds.insetBy(dx: horizontalInset, dy: 0)
        let contentFrame = widthPresentation.contentFrame(in: availableBounds)
        composerView.frame = NSRect(
            x: contentFrame.minX,
            y: bottomInset,
            width: contentFrame.width,
            height: max(0, bounds.height - bottomInset)
        )
    }
}

@MainActor
private final class TextBoxCircleButton: NSButton {
    enum Role {
        case secondary
        case send
    }

    private let role: Role
    private var foregroundColor = NSColor.labelColor

    init(role: Role, target: AnyObject?, action: Selector?) {
        self.role = role
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = TextBoxLayout.iconButtonSize / 2
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TextBoxLayout.iconButtonSize),
            heightAnchor.constraint(equalToConstant: TextBoxLayout.iconButtonSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    func update(foregroundColor: NSColor) {
        self.foregroundColor = foregroundColor
        updateAppearance()
    }

    private func updateAppearance() {
        switch role {
        case .secondary:
            layer?.backgroundColor = foregroundColor.withAlphaComponent(isHighlighted ? 0.16 : 0.10).cgColor
            layer?.borderWidth = 0.8
            layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            contentTintColor = foregroundColor.withAlphaComponent(0.82)
        case .send:
            let opacity: CGFloat = isEnabled ? (isHighlighted ? 0.72 : 1.0) : 0.74
            layer?.backgroundColor = NSColor.white.withAlphaComponent(opacity).cgColor
            layer?.borderWidth = 0
            contentTintColor = NSColor.black.withAlphaComponent(isEnabled ? 0.86 : 0.76)
        }
    }
}

struct TextBoxAttachment: Identifiable {
    let id = UUID()
    let displayName: String
    let submissionText: String
    let submissionPath: String
    let localURL: URL?
    let thumbnail: NSImage?
    let inlineThumbnailSource: TextBoxInlineAttachmentThumbnailSource?
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
        let thumbnail = standardizedURL.flatMap { TextBoxAttachment.makeThumbnail(for: $0) }
        self.thumbnail = thumbnail
        self.inlineThumbnailSource = if let standardizedURL, thumbnail != nil {
            TextBoxInlineAttachmentThumbnailSource(fileURL: standardizedURL)
        } else {
            nil
        }
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
        let thumbnail = TextBoxAttachment.makeThumbnail(for: standardizedURL)
        self.thumbnail = thumbnail
        self.inlineThumbnailSource = thumbnail.map { _ in
            TextBoxInlineAttachmentThumbnailSource(fileURL: standardizedURL)
        }
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
        GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(fileURL)
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
              GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(localURL) else {
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
              GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(localURL) else {
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
              GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(localURL) else {
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

enum TextBoxSubmissionFormatter {
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

@MainActor
enum TextBoxAttachmentPreviewOpening {
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

@MainActor
private final class TextBoxAttachmentPreviewController: NSViewController {
    private let attachment: TextBoxAttachment

    init(attachment: TextBoxAttachment) {
        let metrics = TextBoxAttachmentPreviewMetrics.metrics(for: attachment)
        self.attachment = attachment
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = metrics.contentSize
        view = Self.makeContentView(
            attachment: attachment,
            imageSize: metrics.imageSize,
            openTarget: self,
            openAction: #selector(openInPreview)
        )
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func openInPreview() {
        TextBoxAttachmentPreviewOpening.openInPreview(attachment)
    }

    private static func makeContentView(
        attachment: TextBoxAttachment,
        imageSize: CGSize,
        openTarget: AnyObject,
        openAction: Selector
    ) -> NSView {
        let root = NSView(frame: NSRect(
            origin: .zero,
            size: NSSize(
                width: imageSize.width + TextBoxAttachmentPreviewLayout.previewPadding * 2,
                height: imageSize.height + TextBoxAttachmentPreviewLayout.previewPadding * 2
            )
        ))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.cornerRadius = TextBoxAttachmentPreviewLayout.cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.layer?.masksToBounds = true

        let preview: NSView
        if let thumbnail = attachment.thumbnail {
            let imageView = NSImageView(image: thumbnail)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
            preview = imageView
        } else {
            let placeholder = NSView()
            let imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 42, weight: .regular))
            imageView.contentTintColor = NSColor.labelColor.withAlphaComponent(0.86)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(wrappingLabelWithString: attachment.displayName)
            label.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .medium)
            label.textColor = NSColor.labelColor.withAlphaComponent(0.86)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            let stack = NSStackView(views: [imageView, label])
            stack.orientation = .vertical
            stack.spacing = 10
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            placeholder.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: placeholder.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: placeholder.trailingAnchor, constant: -8),
            ])
            preview = placeholder
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: TextBoxAttachmentPreviewLayout.previewPadding),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -TextBoxAttachmentPreviewLayout.previewPadding),
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: TextBoxAttachmentPreviewLayout.previewPadding),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -TextBoxAttachmentPreviewLayout.previewPadding),
        ])

        if attachment.localURL != nil {
            let title = String(localized: "textbox.openWithPreview.button", defaultValue: "Open with Preview")
            let tooltip = String(localized: "textbox.openInPreview.tooltip", defaultValue: "Open in Preview")
            let button = NSButton(title: title, target: openTarget, action: openAction)
            button.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)
            button.bezelStyle = .roundRect
            button.controlSize = .small
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: root.topAnchor, constant: TextBoxAttachmentPreviewLayout.topButtonPadding),
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -TextBoxAttachmentPreviewLayout.buttonTrailingPadding),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        return root
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

@MainActor
private final class TextBoxMentionCompletionContentView: NSVisualEffectView {
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stackView = NSStackView()
    private var selectionButton: NSButton?
    private var suggestions: [TextBoxMentionSuggestion] = []
    private var onSelect: (TextBoxMentionSuggestion) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 1
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        suggestions: [TextBoxMentionSuggestion],
        selectionIndex: Int,
        searchTerm: String,
        isLoading: Bool,
        onSelect: @escaping (TextBoxMentionSuggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.onSelect = onSelect
        selectionButton = nil
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if suggestions.isEmpty, isLoading {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            let row = NSView()
            progress.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(progress)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 28),
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -8),
                progress.centerXAnchor.constraint(equalTo: row.centerXAnchor),
                progress.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            stackView.addArrangedSubview(row)
        } else {
            for (index, suggestion) in suggestions.enumerated() {
                let button = NSButton(title: "", target: self, action: #selector(selectSuggestion(_:)))
                button.tag = index
                button.isBordered = false
                button.alignment = .left
                button.lineBreakMode = .byTruncatingMiddle
                button.attributedTitle = Self.highlightedTitle(suggestion.title, query: searchTerm)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.wantsLayer = true
                button.layer?.cornerRadius = 5
                button.layer?.cornerCurve = .continuous
                button.layer?.backgroundColor = index == selectionIndex
                    ? NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
                    : NSColor.clear.cgColor
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                NSLayoutConstraint.activate([
                    button.heightAnchor.constraint(equalToConstant: 24),
                    button.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -8),
                ])
                stackView.addArrangedSubview(button)
                if index == selectionIndex {
                    selectionButton = button
                }
            }
        }
        layoutSubtreeIfNeeded()
        if let selectionButton {
            documentView.scrollToVisible(selectionButton.frame.insetBy(dx: 0, dy: -1))
        }
    }

    @objc private func selectSuggestion(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        onSelect(suggestions[sender.tag])
    }

    private static func highlightedTitle(_ title: String, query: String) -> NSAttributedString {
        let font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return attributed }
        let ranges = subsequenceMatchRanges(query: trimmedQuery, in: title)
        for range in ranges {
            attributed.addAttributes(
                [
                    .font: GlobalFontMagnification.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor,
                ],
                range: NSRange(range, in: title)
            )
        }
        return attributed
    }

    private static func subsequenceMatchRanges(query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var queryIndex = query.startIndex
        var textIndex = text.startIndex

        while queryIndex < query.endIndex, textIndex < text.endIndex {
            let nextTextIndex = text.index(after: textIndex)
            let nextQueryIndex = query.index(after: queryIndex)
            let textCharacter = String(text[textIndex..<nextTextIndex])
            let queryCharacter = String(query[queryIndex..<nextQueryIndex])
            if textCharacter.compare(
                queryCharacter,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            ) == .orderedSame {
                ranges.append(textIndex..<nextTextIndex)
                queryIndex = nextQueryIndex
            }
            textIndex = nextTextIndex
        }

        return queryIndex == query.endIndex ? ranges : []
    }
}

final class TextBoxMentionCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

        let submitKey = TextBoxAgentDetection.composedPromptSubmitKey(containsNewline: containsNewline, context: terminalAgentContext)
        if isClaude, containsImageAttachment(inputParts) {
            return claudeSequentialImageDispatchEvents(from: inputParts, submitKey: submitKey)
        }

        let pastePayload = TextBoxSubmissionFormatter.formattedText(from: inputParts)
        return [.pasteText(pastePayload), .namedKey(submitKey)]
    }

    static func launchDispatchEvents(launchCommand: String) -> [DispatchEvent] {
        [
            .pasteText(launchCommand),
            .namedKey(TextBoxTerminalKey.returnKey.rawValue),
        ]
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

    static func sendEvents(
        _ events: [DispatchEvent],
        via surface: TerminalSurface,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
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

        let handled = surface.performExplicitInputBindingAction("paste_from_clipboard")
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

@MainActor
final class TextBoxInputContainer: NSViewController {
    private let panel: TerminalPanel
    let surface: TerminalSurface
    var terminalBackgroundColor: NSColor
    var terminalForegroundColor: NSColor
    var terminalFont: NSFont
    var maxLines: Int
    private var baseTerminalAgentContext: String
    var sessionContentWidthPresentation: SessionContentWidthPresentation
    private var externalOnFocus: () -> Void

    var configuredDefaultSubmitActionID: String {
        UserDefaults.standard.string(forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey)
            ?? TerminalTextBoxInputSettings.defaultSubmitActionID
    }
    var configuredSubmitActionsJSON: String {
        UserDefaults.standard.string(forKey: TerminalTextBoxInputSettings.submitActionsKey) ?? ""
    }
    var submitActionImageCache: [String: NSImage] = [:]
    var submitActionAssetAvailabilityCache: [String: Bool] = [:]
    var cachedSubmitActionsJSON: String?
    var cachedSubmitActions = TerminalTextBoxInputSettings.submitActions(configuredJSON: "")

    var text: String {
        get { panel.textBoxContent }
        set { panel.textBoxContent = newValue }
    }
    var attachments: [TextBoxAttachment] {
        get { panel.textBoxAttachments }
        set { panel.textBoxAttachments = newValue }
    }
    var selectedSubmitActionID: String? {
        get { panel.textBoxState.selectedSubmitActionID }
        set { panel.textBoxState.selectedSubmitActionID = newValue }
    }
    var pendingProviderLaunchAction: TextBoxSubmitAction? {
        get { panel.textBoxState.pendingProviderLaunchAction }
        set { panel.textBoxState.pendingProviderLaunchAction = newValue }
    }
    var pendingProviderLaunchStartedAt: Date? {
        get { panel.textBoxState.pendingProviderLaunchStartedAt }
        set { panel.textBoxState.pendingProviderLaunchStartedAt = newValue }
    }
    var terminalAgentContext: String {
        TerminalPanel.effectiveTerminalAgentContext(
            baseTerminalAgentContext,
            pendingLaunchCommand: panel.textBoxState.pendingLaunchCommand
        )
    }
    var shellActivityState: PanelShellActivityState { panel.shellActivity.state }
    var allowsCommandTemplateSubmit: Bool {
        Self.allowsCommandTemplateSubmit(shellActivityState: shellActivityState)
    }

    var onFocusTextBox: () -> Void {
        { [weak self] in
            guard let self else { return }
            panel.textBoxDidBecomeFocused()
            externalOnFocus()
        }
    }
    var onToggleFocus: () -> Void {
        { [weak panel] in _ = panel?.focusTextBoxInputOrTerminal() }
    }
    var onSelectSubmitAction: (String) -> Void {
        { [weak self] actionID in
            guard let self else { return }
            panel.textBoxState.selectSubmitAction(actionID)
            refreshComposer()
        }
    }
    var onRecordLaunchCommand: (String) -> Void {
        { [weak panel] command in panel?.recordTextBoxLaunchCommand(command) }
    }
    var onClearLaunchCommand: () -> Void {
        { [weak panel] in panel?.clearTextBoxLaunchCommand() }
    }
    var onEscape: () -> Void {
        { [weak panel] in panel?.handleTextBoxEscape() }
    }
    var onTextViewCreated: (TextBoxInputTextView) -> Void {
        { [weak panel] view in panel?.registerTextBoxInputView(view) }
    }
    var onTextViewMovedToWindow: (TextBoxInputTextView) -> Void {
        { [weak panel] view in panel?.textBoxInputViewDidMoveToWindow(view) }
    }
    var onTextViewDismantled: (TextBoxInputTextView) -> Void {
        { [weak panel] view in panel?.preserveTextBoxContentForUnmount(from: view) }
    }

    private var textViewHeight: CGFloat = 0
    private var hasPendingAttachmentUpload = false
    private var hasMarkedText = false
    private let textViewReference = TextBoxInputViewReference()
    private var contentRevision: UInt64 = 0
    var pendingProviderLaunchTimeoutTask: Task<Void, Never>?
    private let commentPool = DiffCommentSubmissionPool.shared

    private let composerRootView = TextBoxComposerRootView()
    private let verticalStack = NSStackView()
    private let mainRow = NSStackView()
    private let editorContainer = NSView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let addFilesButton = TextBoxCircleButton(role: .secondary, target: nil, action: nil)
    private let sendButton = TextBoxCircleButton(role: .send, target: nil, action: nil)
    private let pendingCommentsStack = NSStackView()
    private let pendingCommentsButton = NSButton()
    private let dismissCommentsButton = NSButton()
    private var editorHeightConstraint: NSLayoutConstraint?
    private var textBoxInputView: TextBoxInputView?
    private var commentsPopover: NSPopover?

    private var panelCancellable: AnyCancellable?
    private var commentPoolCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?
    private var stateObservationGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var imageCacheTask: Task<Void, Never>?
    private var loadedImageCacheTaskKey: String?
    private var lastConfiguredDefaultSubmitActionID: String

    private var pendingCommentCount: Int {
        commentPool.pendingCount(workspaceId: surface.owningWorkspace()?.id)
    }

    private var textBasePointSize: CGFloat {
        max(14, terminalFont.pointSize / max(GlobalFontMagnification.scale, 0.01) + 2)
    }

    private var textFont: NSFont {
        GlobalFontMagnification.systemFont(ofSize: textBasePointSize, weight: .regular)
    }

    init(
        panel: TerminalPanel,
        terminalBackgroundColor: NSColor,
        terminalForegroundColor: NSColor,
        terminalFont: NSFont,
        maxLines: Int,
        terminalAgentContext: String,
        sessionContentWidthPresentation: SessionContentWidthPresentation,
        onFocus: @escaping () -> Void
    ) {
        self.panel = panel
        surface = panel.surface
        self.terminalBackgroundColor = terminalBackgroundColor
        self.terminalForegroundColor = terminalForegroundColor
        self.terminalFont = terminalFont
        self.maxLines = maxLines
        baseTerminalAgentContext = terminalAgentContext
        self.sessionContentWidthPresentation = sessionContentWidthPresentation
        externalOnFocus = onFocus
        lastConfiguredDefaultSubmitActionID = UserDefaults.standard.string(
            forKey: TerminalTextBoxInputSettings.defaultSubmitActionKey
        ) ?? TerminalTextBoxInputSettings.defaultSubmitActionID
        super.init(nibName: nil, bundle: nil)
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        panelCancellable?.cancel()
        commentPoolCancellable?.cancel()
        defaultsCancellable?.cancel()
        refreshTask?.cancel()
        imageCacheTask?.cancel()
        pendingProviderLaunchTimeoutTask?.cancel()
        textBoxInputView?.dismantle()
    }

    override func loadView() {
        let inputView = TextBoxInputView(configuration: makeInputConfiguration())
        textBoxInputView = inputView
        configureViewHierarchy(inputView: inputView)
        composerRootView.widthPresentation = sessionContentWidthPresentation
        view = composerRootView
        refreshComposer()
        reconcilePendingProviderLaunch()
        if pendingProviderLaunchAction != nil {
            schedulePendingProviderLaunchTimeout()
        }
    }

    func update(
        terminalBackgroundColor: NSColor,
        terminalForegroundColor: NSColor,
        terminalFont: NSFont,
        maxLines: Int,
        terminalAgentContext: String,
        sessionContentWidthPresentation: SessionContentWidthPresentation,
        onFocus: @escaping () -> Void
    ) {
        self.terminalBackgroundColor = terminalBackgroundColor
        self.terminalForegroundColor = terminalForegroundColor
        self.terminalFont = terminalFont
        self.maxLines = maxLines
        baseTerminalAgentContext = terminalAgentContext
        self.sessionContentWidthPresentation = sessionContentWidthPresentation
        externalOnFocus = onFocus
        reconcilePendingProviderLaunch()
        refreshComposer()
    }

    private func startObserving() {
        panelCancellable = panel.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh(reconcilePendingLaunch: true)
        }
        commentPoolCancellable = commentPool.objectWillChange.sink { [weak self] in
            self?.scheduleRefresh()
        }
        defaultsCancellable = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        ).sink { [weak self] _ in
            self?.handleDefaultsChange()
        }
        observePanelState()
    }

    private func observePanelState() {
        stateObservationGeneration &+= 1
        let generation = stateObservationGeneration
        withObservationTracking {
            _ = panel.textBoxState.selectedSubmitActionID
            _ = panel.textBoxState.pendingProviderLaunchAction
            _ = panel.textBoxState.pendingProviderLaunchStartedAt
            _ = panel.textBoxState.pendingLaunchCommand
            _ = panel.shellActivity.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, stateObservationGeneration == generation else { return }
                reconcilePendingProviderLaunch()
                refreshComposer()
                observePanelState()
            }
        }
    }

    private func scheduleRefresh(reconcilePendingLaunch: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            if reconcilePendingLaunch {
                self.reconcilePendingProviderLaunch()
            }
            self.refreshComposer()
        }
    }

    private func handleDefaultsChange() {
        let nextDefaultSubmitActionID = configuredDefaultSubmitActionID
        refreshSubmitActionsCacheIfNeeded()
        if nextDefaultSubmitActionID != lastConfiguredDefaultSubmitActionID,
           selectedSubmitActionID == nil,
           pendingProviderLaunchAction != nil {
            cancelPendingProviderLaunch()
        }
        lastConfiguredDefaultSubmitActionID = nextDefaultSubmitActionID
        loadedImageCacheTaskKey = nil
        refreshComposer()
    }

    private func configureViewHierarchy(inputView: TextBoxInputView) {
        let contentView = composerRootView.composerView.contentView

        verticalStack.orientation = .vertical
        verticalStack.alignment = .leading
        verticalStack.spacing = 6
        verticalStack.detachesHiddenViews = true
        verticalStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(verticalStack)

        configurePendingCommentsStack()
        verticalStack.addArrangedSubview(pendingCommentsStack)

        mainRow.orientation = .horizontal
        mainRow.alignment = .bottom
        mainRow.spacing = 6
        mainRow.distribution = .fill
        mainRow.translatesAutoresizingMaskIntoConstraints = false
        verticalStack.addArrangedSubview(mainRow)

        addFilesButton.target = self
        addFilesButton.action = #selector(chooseFilesFromButton)
        let addTooltip = String(localized: "textbox.addFiles.tooltip", defaultValue: "Add Files")
        addFilesButton.toolTip = addTooltip
        addFilesButton.setAccessibilityLabel(addTooltip)
        addFilesButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: addTooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: TextBoxLayout.iconSymbolSize,
                weight: .semibold
            ))
        mainRow.addArrangedSubview(buttonWrapper(addFilesButton))

        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        inputView.translatesAutoresizingMaskIntoConstraints = false
        inputView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editorContainer.addSubview(inputView)

        placeholderLabel.stringValue = String(localized: "textbox.placeholder", defaultValue: "Prompt or command")
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isBordered = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editorContainer.addSubview(placeholderLabel)

        let heightConstraint = editorContainer.heightAnchor.constraint(
            equalToConstant: max(TextBoxLayout.minimumTextHeight, heightForLines(TextBoxLayout.minLines))
        )
        editorHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            inputView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            inputView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            inputView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            inputView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: editorContainer.leadingAnchor,
                constant: TextBoxLayout.textInset.width
            ),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: editorContainer.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(
                equalTo: editorContainer.centerYAnchor,
                constant: TextBoxLayout.placeholderVerticalOffset
            ),
        ])
        mainRow.addArrangedSubview(editorContainer)

        sendButton.target = self
        sendButton.action = #selector(submitFromButton)
        mainRow.addArrangedSubview(buttonWrapper(sendButton))

        NSLayoutConstraint.activate([
            verticalStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: TextBoxLayout.pillHorizontalPadding
            ),
            verticalStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -TextBoxLayout.pillHorizontalPadding
            ),
            verticalStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: TextBoxLayout.pillVerticalPadding
            ),
            verticalStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -TextBoxLayout.pillVerticalPadding
            ),
            mainRow.widthAnchor.constraint(equalTo: verticalStack.widthAnchor),
        ])
    }

    private func configurePendingCommentsStack() {
        pendingCommentsStack.orientation = .horizontal
        pendingCommentsStack.alignment = .centerY
        pendingCommentsStack.spacing = 5
        pendingCommentsStack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 5)
        pendingCommentsStack.wantsLayer = true
        pendingCommentsStack.layer?.cornerRadius = 13
        pendingCommentsStack.layer?.cornerCurve = .continuous
        pendingCommentsStack.layer?.borderWidth = 1
        pendingCommentsStack.translatesAutoresizingMaskIntoConstraints = false
        pendingCommentsStack.heightAnchor.constraint(equalToConstant: 26).isActive = true

        pendingCommentsButton.isBordered = false
        pendingCommentsButton.imagePosition = .imageLeading
        pendingCommentsButton.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        pendingCommentsButton.target = self
        pendingCommentsButton.action = #selector(showPendingComments)
        pendingCommentsButton.toolTip = String(
            localized: "textbox.diffComments.preview",
            defaultValue: "Show comments"
        )
        pendingCommentsStack.addArrangedSubview(pendingCommentsButton)

        dismissCommentsButton.isBordered = false
        dismissCommentsButton.imagePosition = .imageOnly
        dismissCommentsButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        dismissCommentsButton.target = self
        dismissCommentsButton.action = #selector(dismissPendingCommentsFromButton)
        dismissCommentsButton.toolTip = String(
            localized: "textbox.diffComments.dismiss",
            defaultValue: "Dismiss comments without sending"
        )
        dismissCommentsButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dismissCommentsButton.widthAnchor.constraint(equalToConstant: 16),
            dismissCommentsButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        pendingCommentsStack.addArrangedSubview(dismissCommentsButton)
    }

    private func buttonWrapper(_ button: NSButton) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(button)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalToConstant: TextBoxLayout.iconButtonSize),
            wrapper.heightAnchor.constraint(equalToConstant: TextBoxLayout.iconButtonSize + TextBoxLayout.buttonBottomPadding),
            button.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            button.topAnchor.constraint(equalTo: wrapper.topAnchor),
        ])
        return wrapper
    }

    private func makeInputConfiguration() -> TextBoxInputConfiguration {
        TextBoxInputConfiguration(
            text: { [weak self] in self?.text ?? "" },
            setText: { [weak self] value in
                self?.text = value
                self?.scheduleRefresh()
            },
            attachments: { [weak self] in self?.attachments ?? [] },
            setAttachments: { [weak self] value in
                self?.attachments = value
                self?.scheduleRefresh()
            },
            textViewHeight: { [weak self] in self?.textViewHeight ?? 0 },
            setTextViewHeight: { [weak self] value in
                self?.textViewHeight = value
                self?.refreshComposer()
            },
            hasPendingAttachmentUpload: { [weak self] in self?.hasPendingAttachmentUpload ?? false },
            setHasPendingAttachmentUpload: { [weak self] value in
                self?.hasPendingAttachmentUpload = value
                self?.scheduleRefresh()
            },
            font: textFont,
            backgroundColor: terminalBackgroundColor,
            foregroundColor: terminalForegroundColor,
            terminalTitle: terminalAgentContext,
            completionRootDirectory: completionRootDirectory,
            onSubmit: { [weak self] in self?.submit() },
            onEscape: onEscape,
            onFocusTextBox: onFocusTextBox,
            onToggleFocus: onToggleFocus,
            onCycleSubmitAction: { [weak self] in self?.cycleSubmitAction() },
            onForwardText: { [weak self] text, focusTerminalAfterSend in
                self?.forwardText(text, focusTerminalAfterSend: focusTerminalAfterSend)
            },
            onForwardKey: { [weak self] key in self?.forwardKey(key) },
            onForwardControl: { [weak self] key in self?.forwardControl(key) },
            onPaste: { [weak self] pasteboard, textView in
                self?.handlePaste(pasteboard, into: textView) ?? false
            },
            onInsertFileURLs: { [weak self] urls, textView in
                self?.insertSelectedFileURLs(urls, into: textView) ?? false
            },
            onChooseFiles: { [weak self] in self?.chooseFiles() },
            onContentChanged: { [weak self] in self?.markContentChanged() },
            onMarkedTextStateChanged: { [weak self] value in self?.updateMarkedTextState(value) },
            onTextViewCreated: { [weak self] textView in self?.registerTextView(textView) },
            onTextViewMovedToWindow: onTextViewMovedToWindow,
            onTextViewDismantled: onTextViewDismantled
        )
    }

    private func refreshComposer() {
        guard isViewLoaded, let textBoxInputView else { return }
        refreshSubmitActionsCacheIfNeeded()
        textBoxInputView.update(configuration: makeInputConfiguration())

        let minHeight = max(TextBoxLayout.minimumTextHeight, heightForLines(TextBoxLayout.minLines))
        let maxHeight = heightForLines(max(TextBoxLayout.minLines, maxLines))
        let clampedHeight = max(minHeight, min(maxHeight, textViewHeight))
        editorHeightConstraint?.constant = clampedHeight

        let count = pendingCommentCount
        pendingCommentsStack.isHidden = count == 0
        pendingCommentsButton.title = pendingCommentsLabel(count)
        pendingCommentsButton.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .medium)
        pendingCommentsButton.contentTintColor = terminalForegroundColor.withAlphaComponent(0.92)
        pendingCommentsButton.setAccessibilityLabel(pendingCommentsLabel(count))
        dismissCommentsButton.contentTintColor = terminalForegroundColor.withAlphaComponent(0.62)
        pendingCommentsStack.layer?.backgroundColor = terminalForegroundColor.withAlphaComponent(0.10).cgColor
        pendingCommentsStack.layer?.borderColor = terminalForegroundColor.withAlphaComponent(0.18).cgColor

        placeholderLabel.font = GlobalFontMagnification.systemFont(ofSize: textBasePointSize)
        placeholderLabel.textColor = terminalForegroundColor.withAlphaComponent(0.36)
        placeholderLabel.isHidden = !TextBoxSubmitAvailability.shouldShowPlaceholder(
            text: text,
            attachmentCount: attachments.count,
            hasMarkedText: hasMarkedText
        )

        let baseCanSend = TextBoxSubmitAvailability.shouldEnableSubmit(
            text: text,
            attachmentCount: attachments.count + count,
            hasPendingAttachmentUpload: hasPendingAttachmentUpload,
            hasMarkedText: hasMarkedText
        )
        let canSend = Self.shouldEnableSubmitButton(
            baseCanSend: baseCanSend,
            pendingProviderLaunchAction: pendingProviderLaunchAction,
            action: effectiveSubmitAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        )
        let presentation = submitActionPresentation
        sendButton.isEnabled = canSend
        sendButton.toolTip = presentation.helpText
        sendButton.setAccessibilityLabel(presentation.accessibilityLabel)
        sendButton.image = nativeSubmitActionImage(presentation.action, forSendButton: true)
        sendButton.menu = makeSubmitActionMenu()
        addFilesButton.update(foregroundColor: terminalForegroundColor)
        sendButton.update(foregroundColor: terminalForegroundColor)

        composerRootView.composerView.update(
            foregroundColor: terminalForegroundColor,
            backgroundColor: terminalBackgroundColor
        )
        composerRootView.widthPresentation = sessionContentWidthPresentation
        let commentsHeight: CGFloat = count > 0 ? 38 : 0
        composerRootView.contentHeight = max(clampedHeight, TextBoxLayout.iconButtonSize + 3)
            + commentsHeight
            + 7
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true

        let imageTaskKey = submitActionImageCacheTaskKey
        if loadedImageCacheTaskKey != imageTaskKey {
            loadedImageCacheTaskKey = imageTaskKey
            imageCacheTask?.cancel()
            let keys = submitActionImageCacheKeys
            imageCacheTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await refreshSubmitActionImageCache(keys: keys)
                guard !Task.isCancelled else { return }
                sendButton.image = nativeSubmitActionImage(submitActionPresentation.action, forSendButton: true)
                sendButton.menu = makeSubmitActionMenu()
            }
        }
    }

    private func nativeSubmitActionImage(
        _ action: TextBoxSubmitAction,
        forSendButton: Bool
    ) -> NSImage? {
        let image: NSImage?
        if let cached = submitActionNSImage(for: action) {
            image = cached.copy() as? NSImage
        } else if let assetName = resolvedSubmitActionAssetName(for: action) {
            image = CmuxResolvedIconRenderer().image(
                for: submitActionIconRequest(
                    assetName: assetName,
                    tintColor: forSendButton && action.id == "codex" ? .black : nil
                ),
                appearance: view.effectiveAppearance
            )
        } else {
            image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(
                    pointSize: TextBoxLayout.sendSymbolSize,
                    weight: .bold
                ))
        }
        if forSendButton, action.id == "codex" {
            image?.isTemplate = true
        }
        return image
    }

    private func makeSubmitActionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if pendingProviderLaunchAction != nil {
            let cancel = NSMenuItem(
                title: String(
                    localized: "textbox.submitAction.cancelPending",
                    defaultValue: "Cancel Pending Launch"
                ),
                action: #selector(cancelPendingLaunchFromMenu),
                keyEquivalent: ""
            )
            cancel.target = self
            cancel.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            cancel.isEnabled = true
            menu.addItem(cancel)
            menu.addItem(.separator())
        }
        if allowsSubmitActionSelection {
            for action in submitActions {
                let item = NSMenuItem(
                    title: TextBoxSubmitActionPresentation.localizedTitle(for: action),
                    action: #selector(selectSubmitActionFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = action.id
                item.state = action.id == selectedSubmitAction.id ? .on : .off
                item.image = action.id == selectedSubmitAction.id
                    ? nil
                    : nativeSubmitActionImage(action, forSendButton: false)
                item.isEnabled = true
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let docs = NSMenuItem(
            title: String(
                localized: "textbox.submitAction.docs",
                defaultValue: "TextBox Submit Actions Docs"
            ),
            action: #selector(openSubmitActionsDocumentationFromMenu),
            keyEquivalent: ""
        )
        docs.target = self
        docs.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        docs.isEnabled = true
        menu.addItem(docs)
        return menu
    }

    @objc private func chooseFilesFromButton() {
        chooseFiles()
    }

    @objc private func submitFromButton() {
        guard sendButton.isEnabled else {
            NSSound.beep()
            return
        }
        submit()
    }

    @objc private func cancelPendingLaunchFromMenu() {
        cancelPendingProviderLaunch()
        refreshComposer()
    }

    @objc private func selectSubmitActionFromMenu(_ sender: NSMenuItem) {
        guard let actionID = sender.representedObject as? String else { return }
        onSelectSubmitAction(actionID)
    }

    @objc private func openSubmitActionsDocumentationFromMenu() {
        openSubmitActionsDocumentation()
    }

    @objc private func showPendingComments() {
        let entries = surface.owningWorkspace().map {
            commentPool.entriesByWorkspace[$0.id] ?? []
        } ?? []
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = entries
            .map { $0.submissionText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let controller = NSViewController()
        controller.view = scrollView
        controller.preferredContentSize = NSSize(width: 440, height: 240)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        commentsPopover?.performClose(nil)
        commentsPopover = popover
        popover.show(relativeTo: pendingCommentsButton.bounds, of: pendingCommentsButton, preferredEdge: .maxY)
    }

    @objc private func dismissPendingCommentsFromButton() {
        dismissPendingComments()
        commentsPopover?.performClose(nil)
        commentsPopover = nil
        refreshComposer()
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

    private func dismissPendingComments() {
        guard let workspaceId = surface.owningWorkspace()?.id else { return }
        let dismissed = DiffCommentSubmissionPool.shared.consumeAll(workspaceId: workspaceId)
        // Mark consumed so viewer reloads do not resurrect the chip; the
        // comments stay saved in the diff viewer.
        for (repoRoot, entries) in Dictionary(grouping: dismissed, by: \.repoRoot) {
            DiffCommentStore.shared.markConsumed(ids: entries.map(\.commentId), repoRoot: repoRoot)
        }
    }

    private func pendingCommentsLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "textbox.diffComments.one", defaultValue: "1 comment")
            : String(
                format: String(localized: "textbox.diffComments.many", defaultValue: "%d comments"),
                count
            )
    }

    func submit() {
        let textView = textViewReference.textView
        guard TextBoxSubmitAvailability.shouldSubmit(
            hasPendingAttachmentUpload: textView?.hasPendingAttachmentUploadPlaceholder() ?? hasPendingAttachmentUpload,
            hasMarkedText: textView?.hasMarkedText() ?? hasMarkedText
        ) else {
            NSSound.beep()
            return
        }
        let submittedParts = textView?.submissionParts()
            ?? [TextBoxSubmissionPart.text(text.trimmingCharacters(in: .newlines))]
        let poolWorkspaceId = surface.owningWorkspace()?.id
        let hasTypedContent = TextBoxSubmissionFormatter.hasSubmittableContent(submittedParts)
        guard hasTypedContent || pendingCommentCount > 0 else {
            NSSound.beep()
            return
        }
        if isPendingProviderLaunchAwaitingAgent {
            NSSound.beep()
            return
        }
        let launchAction = effectiveSubmitAction
        if Self.shouldFailClosedForCommandTemplate(
            action: launchAction,
            shouldForceTextEntrySubmit: shouldForceTextEntrySubmit,
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit
        ) {
            NSSound.beep()
            return
        }
        if let launchCommand = providerLaunchCommand(for: launchAction) {
            startPendingProviderLaunch(launchAction)
            onRecordLaunchCommand(launchAction.launchContextCommand() ?? launchCommand)
            TextBoxSubmit.sendEvents(
                TextBoxSubmit.launchDispatchEvents(launchCommand: launchCommand),
                via: surface
            ) { completionContext in
                if !completionContext.didSubmit {
                    self.clearPendingProviderLaunch()
                    self.onClearLaunchCommand()
                    NSSound.beep()
                }
            }
            return
        }
        // Claim the workspace's pending diff comments: this submission carries
        // them, and the chip clears from every other TextBox in the workspace.
        let pendingComments = poolWorkspaceId.map {
            DiffCommentSubmissionPool.shared.consumeAll(workspaceId: $0)
        } ?? []
        var partsToSend = submittedParts
        if !pendingComments.isEmpty {
            let bundle = pendingComments.map(\.submissionText).joined(separator: "\n")
            partsToSend.append(.text(hasTypedContent ? "\n\n" + bundle : bundle))
        }
        let submittedTextView = textView
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
        let submitPlan = dispatchPlan(partsToSend, applying: effectiveSubmitAction)
        if let launchContextCommand = submitPlan.launchContextCommand {
            startPendingProviderLaunch(launchAction)
            onRecordLaunchCommand(launchContextCommand)
        }
        TextBoxSubmit.sendEvents(
            submitPlan.events,
            via: surface
        ) { completionContext in
            guard completionContext.didSubmit else {
                if submitPlan.launchContextCommand != nil {
                    self.clearPendingProviderLaunch()
                    self.onClearLaunchCommand()
                }
                if let poolWorkspaceId, !pendingComments.isEmpty {
                    DiffCommentSubmissionPool.shared.restorePending(
                        pendingComments,
                        workspaceId: poolWorkspaceId
                    )
                }
                guard TextBoxFailedSubmitRollbackPolicy.shouldRestore(
                    rollbackSnapshot: rollbackSnapshot,
                    currentSnapshot: self.currentRollbackSnapshot()
                ) else {
                    NSSound.beep()
                    return
                }
                if let preservedContent {
                    submittedTextView?.installPreservedContent(preservedContent)
                } else {
                    self.text = TextBoxSubmissionFormatter.formattedText(from: submittedParts)
                    self.attachments = submittedParts.compactMap { part in
                        if case .attachment(let attachment) = part { return attachment }
                        return nil
                    }
                }
                NSSound.beep()
                return
            }
            if !pendingComments.isEmpty {
                for (repoRoot, entries) in Dictionary(grouping: pendingComments, by: \.repoRoot) {
                    DiffCommentStore.shared.markConsumed(ids: entries.map(\.commentId), repoRoot: repoRoot)
                }
            }
            self.resetPanelSubmitActionAfterSuccessfulSubmit(submittedAction: launchAction)
            let submittedAttachments = submittedParts.compactMap { part -> TextBoxAttachment? in
                if case .attachment(let attachment) = part { return attachment }
                return nil
            }
            submittedTextView?.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions(submittedAttachments)
            let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: submittedParts,
                terminalAgentContext: submitPlan.cleanupTerminalAgentContext,
                completionContext: completionContext
            )
            submittedTextView?.cleanupDisposableAttachmentFiles(cleanupAttachments)
        }
    }

    private func resetPanelSubmitActionAfterSuccessfulSubmit(submittedAction: TextBoxSubmitAction) {
        let nextID = Self.panelSubmitActionIDAfterSuccessfulSubmit(
            currentSubmitActionID: effectiveSubmitActionID,
            submittedAction: submittedAction
        )
        guard nextID != effectiveSubmitActionID else { return }
        selectedSubmitActionID = nextID
    }

    private func markContentChanged() {
        _ = advanceContentRevision()
    }

    private func updateMarkedTextState(_ nextValue: Bool) {
        guard hasMarkedText != nextValue else { return }
        hasMarkedText = nextValue
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

    /// Records the newly constructed text view and lets the panel restore draft state.
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
            self.focusTextViewAfterFilePanel(textView)
            guard response == .OK else { return }
            if !self.insertSelectedFileURLs(panel.urls, into: textView) {
                NSSound.beep()
                self.focusTextViewAfterFilePanel(textView)
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
                    guard self.textViewReference.textView === textView,
                          textView.removePendingAttachmentUploadPlaceholder(id: placeholderID) else {
                        return
                    }
                    self.attachments = textView.inlineAttachments()
                    self.text = textView.plainText()
                }

                surface?.hostedView.endImageTransferIndicator(for: operation)
                guard operation.finish() else {
                    removePendingPlaceholder()
                    GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                    return
                }

                switch result {
                case .success(let remotePaths):
                    guard !remotePaths.isEmpty else {
                        removePendingPlaceholder()
                        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
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
                        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                        NSSound.beep()
                        return
                    }
                    guard self.textViewReference.textView === textView,
                          textView.canAcceptPendingAttachmentUpload(validationToken: uploadValidationToken) else {
                        removePendingPlaceholder()
                        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                        return
                    }
                    guard textView.replacePendingAttachmentUploadPlaceholder(
                        id: placeholderID,
                        with: newAttachments
                    ) else {
                        removePendingPlaceholder()
                        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                        return
                    }
                    self.attachments = textView.inlineAttachments()
                    self.text = textView.plainText()
                case .failure:
                    removePendingPlaceholder()
                    GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
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

@MainActor
struct TextBoxInputConfiguration {
    private let readText: () -> String
    private let writeText: (String) -> Void
    private let readAttachments: () -> [TextBoxAttachment]
    private let writeAttachments: ([TextBoxAttachment]) -> Void
    private let readTextViewHeight: () -> CGFloat
    private let writeTextViewHeight: (CGFloat) -> Void
    private let readHasPendingAttachmentUpload: () -> Bool
    private let writeHasPendingAttachmentUpload: (Bool) -> Void
    let font: NSFont
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let terminalTitle: String
    let completionRootDirectory: String?
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onFocusTextBox: () -> Void
    let onToggleFocus: () -> Void
    let onCycleSubmitAction: () -> Void
    let onForwardText: (String, Bool) -> Void
    let onForwardKey: (TextBoxTerminalKey) -> Void
    let onForwardControl: (String) -> Void
    let onPaste: (NSPasteboard, TextBoxInputTextView) -> Bool
    let onInsertFileURLs: ([URL], TextBoxInputTextView) -> Bool
    let onChooseFiles: () -> Void
    let onContentChanged: () -> Void
    let onMarkedTextStateChanged: (Bool) -> Void
    let onTextViewCreated: (TextBoxInputTextView) -> Void
    let onTextViewMovedToWindow: (TextBoxInputTextView) -> Void
    let onTextViewDismantled: (TextBoxInputTextView) -> Void

    var text: String {
        get { readText() }
        nonmutating set { writeText(newValue) }
    }

    var attachments: [TextBoxAttachment] {
        get { readAttachments() }
        nonmutating set { writeAttachments(newValue) }
    }

    var textViewHeight: CGFloat {
        get { readTextViewHeight() }
        nonmutating set { writeTextViewHeight(newValue) }
    }

    var hasPendingAttachmentUpload: Bool {
        get { readHasPendingAttachmentUpload() }
        nonmutating set { writeHasPendingAttachmentUpload(newValue) }
    }

    init(
        text: @escaping () -> String,
        setText: @escaping (String) -> Void,
        attachments: @escaping () -> [TextBoxAttachment],
        setAttachments: @escaping ([TextBoxAttachment]) -> Void,
        textViewHeight: @escaping () -> CGFloat,
        setTextViewHeight: @escaping (CGFloat) -> Void,
        hasPendingAttachmentUpload: @escaping () -> Bool,
        setHasPendingAttachmentUpload: @escaping (Bool) -> Void,
        font: NSFont,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        terminalTitle: String,
        completionRootDirectory: String?,
        onSubmit: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onFocusTextBox: @escaping () -> Void,
        onToggleFocus: @escaping () -> Void,
        onCycleSubmitAction: @escaping () -> Void = {},
        onForwardText: @escaping (String, Bool) -> Void,
        onForwardKey: @escaping (TextBoxTerminalKey) -> Void,
        onForwardControl: @escaping (String) -> Void,
        onPaste: @escaping (NSPasteboard, TextBoxInputTextView) -> Bool,
        onInsertFileURLs: @escaping ([URL], TextBoxInputTextView) -> Bool,
        onChooseFiles: @escaping () -> Void,
        onContentChanged: @escaping () -> Void,
        onMarkedTextStateChanged: @escaping (Bool) -> Void = { _ in },
        onTextViewCreated: @escaping (TextBoxInputTextView) -> Void,
        onTextViewMovedToWindow: @escaping (TextBoxInputTextView) -> Void,
        onTextViewDismantled: @escaping (TextBoxInputTextView) -> Void
    ) {
        readText = text
        writeText = setText
        readAttachments = attachments
        writeAttachments = setAttachments
        readTextViewHeight = textViewHeight
        writeTextViewHeight = setTextViewHeight
        readHasPendingAttachmentUpload = hasPendingAttachmentUpload
        writeHasPendingAttachmentUpload = setHasPendingAttachmentUpload
        self.font = font
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.terminalTitle = terminalTitle
        self.completionRootDirectory = completionRootDirectory
        self.onSubmit = onSubmit
        self.onEscape = onEscape
        self.onFocusTextBox = onFocusTextBox
        self.onToggleFocus = onToggleFocus
        self.onCycleSubmitAction = onCycleSubmitAction
        self.onForwardText = onForwardText
        self.onForwardKey = onForwardKey
        self.onForwardControl = onForwardControl
        self.onPaste = onPaste
        self.onInsertFileURLs = onInsertFileURLs
        self.onChooseFiles = onChooseFiles
        self.onContentChanged = onContentChanged
        self.onMarkedTextStateChanged = onMarkedTextStateChanged
        self.onTextViewCreated = onTextViewCreated
        self.onTextViewMovedToWindow = onTextViewMovedToWindow
        self.onTextViewDismantled = onTextViewDismantled
    }
}

@MainActor
final class TextBoxInputCoordinator: NSObject, NSTextViewDelegate {
    var configuration: TextBoxInputConfiguration
    private var pendingAttachmentUploadStateForNextLayout: Bool?
    private var pendingMarkedTextStateForNextLayout: Bool?
    private var deliveredMarkedTextState: Bool?

    init(configuration: TextBoxInputConfiguration) {
        self.configuration = configuration
    }

    /// Captures pending-upload state once after native editor construction restores AppKit storage.
    func queuePendingAttachmentUploadStateSync(from textView: TextBoxInputTextView) {
        pendingAttachmentUploadStateForNextLayout = textView.hasPendingAttachmentUploadPlaceholder()
    }

    func queuePendingMarkedTextStateSync(from textView: TextBoxInputTextView) {
        pendingMarkedTextStateForNextLayout = textView.hasMarkedText()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? TextBoxInputTextView else { return }
        textView.normalizeTextBaselineOffsets()
        publishTextViewContent(textView)
        noteMarkedTextStateChanged(textView.hasMarkedText(), from: textView)
        if configuration.text.isEmpty,
           configuration.attachments.isEmpty,
           !textView.hasPendingAttachmentUploadPlaceholder()
        {
            textView.invalidatePendingAttachmentUploads()
        }
        if !textView.isHandlingDidChangeText {
            textView.refreshMentionCompletions()
        }
        recalculateHeight(textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? TextBoxInputTextView else { return }
        noteMarkedTextStateChanged(textView.hasMarkedText(), from: textView)
        let color = textView.textColor ?? .labelColor
        textView.layer?.borderColor = color.withAlphaComponent(
            textView.window?.firstResponder === textView ? 0.45 : 0.24
        ).cgColor
        textView.refreshInlineAttachmentFocus()
        if !textView.isHandlingDidChangeText {
            textView.refreshMentionCompletions()
        }
    }

    func noteMarkedTextStateChanged(_ hasMarkedText: Bool, from textView: TextBoxInputTextView? = nil) {
        let pendingMarkedTextState = pendingMarkedTextStateForNextLayout
        if textView != nil {
            pendingMarkedTextStateForNextLayout = nil
        }
        if !hasMarkedText,
           let textView,
           deliveredMarkedTextState == true || pendingMarkedTextState == true
        {
            publishTextViewContent(textView)
        }
        if deliveredMarkedTextState != hasMarkedText {
            configuration.onMarkedTextStateChanged(hasMarkedText)
        }
        deliveredMarkedTextState = hasMarkedText
    }

    private func publishTextViewContent(_ textView: TextBoxInputTextView) {
        let nextText = textView.plainText()
        let nextAttachments = textView.inlineAttachments()
        let nextHasPendingAttachmentUpload = textView.hasPendingAttachmentUploadPlaceholder()
        let contentChanged = configuration.text != nextText
            || configuration.attachments.map(\.id) != nextAttachments.map(\.id)
            || configuration.hasPendingAttachmentUpload != nextHasPendingAttachmentUpload
        configuration.text = nextText
        configuration.attachments = nextAttachments
        configuration.hasPendingAttachmentUpload = nextHasPendingAttachmentUpload
        if contentChanged {
            configuration.onContentChanged()
        }
    }

    func recalculateHeight(_ textView: NSTextView, lineFragmentCount measuredLineFragmentCount: Int? = nil) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let lineFragmentCount = measuredLineFragmentCount
            ?? (textView as? TextBoxInputTextView)?.visualLineFragmentCount()
            ?? TextBoxInputTextView.visualLineFragmentCount(
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
        if let textBoxView = textView as? TextBoxInputTextView {
            if measuredLineFragmentCount == nil {
                textBoxView.recenterSingleLineTextContainer(lineFragmentCount: lineFragmentCount)
            }
            applyPendingAttachmentUploadStateSyncIfNeeded()
            applyPendingMarkedTextStateSyncIfNeeded()
        }
        let preferredHeight: CGFloat

        if lineFragmentCount <= TextBoxLayout.minLines {
            let font = textView.font ?? configuration.font
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            preferredHeight = max(
                TextBoxLayout.minimumTextHeight,
                lineHeight + TextBoxLayout.textInset.height * 2
            )
        } else {
            let font = textView.font ?? configuration.font
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
        if abs(configuration.textViewHeight - preferredHeight) > 0.5 {
            configuration.textViewHeight = preferredHeight
        }
    }

    private func applyPendingAttachmentUploadStateSyncIfNeeded() {
        guard let hasPendingUpload = pendingAttachmentUploadStateForNextLayout else { return }
        pendingAttachmentUploadStateForNextLayout = nil
        guard configuration.hasPendingAttachmentUpload != hasPendingUpload else { return }
        configuration.hasPendingAttachmentUpload = hasPendingUpload
    }

    private func applyPendingMarkedTextStateSyncIfNeeded() {
        guard let hasMarkedText = pendingMarkedTextStateForNextLayout else { return }
        pendingMarkedTextStateForNextLayout = nil
        noteMarkedTextStateChanged(hasMarkedText)
    }
}

@MainActor
final class TextBoxInputView: NSScrollView {
    let textView: TextBoxInputTextView
    let coordinator: TextBoxInputCoordinator
    private var isDismantled = false

    init(configuration: TextBoxInputConfiguration) {
        textView = TextBoxInputTextView()
        coordinator = TextBoxInputCoordinator(configuration: configuration)
        super.init(frame: .zero)

        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        documentView = textView

        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: TextBoxLayout.minimumTextHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
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

        update(configuration: configuration)
        configuration.onTextViewCreated(textView)
        coordinator.queuePendingAttachmentUploadStateSync(from: textView)
        coordinator.queuePendingMarkedTextStateSync(from: textView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: TextBoxInputConfiguration) {
        coordinator.configuration = configuration
        textView.onMoveToWindow = configuration.onTextViewMovedToWindow
        let contentSize = contentView.bounds.size
        if contentSize.width > 0 {
            textView.frame.size.width = contentSize.width
            textView.textContainer?.containerSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        // The mounted AppKit editor owns the live draft. State publication can
        // lag this update, so an older snapshot must not overwrite its storage.
        textView.font = configuration.font
        textView.textColor = configuration.foregroundColor
        textView.backgroundColor = .clear
        textView.insertionPointColor = configuration.foregroundColor
        textView.terminalTitle = configuration.terminalTitle
        textView.completionRootDirectory = configuration.completionRootDirectory
        textView.onSubmit = configuration.onSubmit
        textView.onEscape = configuration.onEscape
        textView.onFocusTextBox = configuration.onFocusTextBox
        textView.onToggleFocus = configuration.onToggleFocus
        textView.onCycleSubmitAction = configuration.onCycleSubmitAction
        textView.onForwardText = configuration.onForwardText
        textView.onForwardKey = configuration.onForwardKey
        textView.onForwardControl = configuration.onForwardControl
        textView.onPaste = configuration.onPaste
        textView.onInsertFileURLs = configuration.onInsertFileURLs
        textView.onChooseFiles = configuration.onChooseFiles
        textView.onMarkedTextStateChanged = { [weak coordinator, weak textView] hasMarkedText in
            coordinator?.noteMarkedTextStateChanged(hasMarkedText, from: textView)
        }
        textView.refreshInlineAttachmentCells(
            font: configuration.font,
            foregroundColor: configuration.foregroundColor
        )
        textView.recenterSingleLineTextContainer()
        textView.wantsLayer = true
        textView.layer?.backgroundColor = NSColor.clear.cgColor
        textView.layer?.borderWidth = 0
        textView.delegate = coordinator
        textView.onLayoutCompleted = { [weak coordinator] textView, lineFragmentCount in
            coordinator?.recalculateHeight(textView, lineFragmentCount: lineFragmentCount)
        }
    }

    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        coordinator.configuration.onTextViewDismantled(textView)
        textView.onMoveToWindow = { _ in }
        textView.onLayoutCompleted = { _, _ in }
        textView.invalidatePendingAttachmentUploads()
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }
}

final class TextBoxInputTextView: NSTextView {
    fileprivate private(set) var isHandlingDidChangeText = false

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
    var onCycleSubmitAction: () -> Void = {}
    var onForwardText: (String, Bool) -> Void = { _, _ in }
    var onForwardKey: (TextBoxTerminalKey) -> Void = { _ in }
    var onForwardControl: (String) -> Void = { _ in }
    var onPaste: (NSPasteboard, TextBoxInputTextView) -> Bool = { _, _ in false }
    var onInsertFileURLs: ([URL], TextBoxInputTextView) -> Bool = { _, _ in false }
    var onChooseFiles: () -> Void = {}
    var onMoveToWindow: (TextBoxInputTextView) -> Void = { _ in }
    var onLayoutCompleted: (TextBoxInputTextView, Int) -> Void = { _, _ in }
    var onMarkedTextStateChanged: (Bool) -> Void = { _ in }
    private var isReportingLayoutCompletion = false

    private static let localControlKeys: Set<String> = ["a", "e", "f", "b", "n", "p", "k", "h"]
    private static let pendingAttachmentUploadPlaceholderCharacter = "\u{200B}"
    private static let pendingAttachmentUploadPlaceholderAttribute = NSAttributedString.Key(
        "cmux.textBoxPendingAttachmentUploadID"
    )
    private var attachmentPreviewPopover: NSPopover?
    private var attachmentPreviewCharacterIndex: Int?
    var focusedAttachmentCharacterIndex: Int?
    private weak var renderedFocusedInlineAttachment: TextBoxInlineTextAttachment?
    private var inlineAttachmentsByID: [UUID: [TextBoxInlineTextAttachment]] = [:]
    private var inlineAttachmentRendererStorage: TextBoxInlineAttachmentRenderer?
    private var inlineAttachmentRenderer: TextBoxInlineAttachmentRenderer {
        if let inlineAttachmentRendererStorage {
            return inlineAttachmentRendererStorage
        }
        let renderer = TextBoxInlineAttachmentRenderer { [weak self] attachmentID in
            self?.refreshInlineAttachmentCell(forAttachmentID: attachmentID)
        }
        inlineAttachmentRendererStorage = renderer
        return renderer
    }
    private var attachmentKeyDownMonitor: Any?
    private var preserveAttachmentFocusOnNextResign = false
    private var attachmentUploadInvalidationGeneration: UInt64 = 0
    private var mentionCompletionPanel: TextBoxMentionCompletionPanel?
    private var mentionCompletionPanelHost: TextBoxMentionCompletionContentView?
    private var mentionCompletionControllerStorage: TextBoxMentionCompletionController?
    private var warmedMentionCompletionRootDirectory: String?
    private var mentionCompletionWarmupTask: Task<Void, Never>?
    private var mentionCompletionWindowObserverTokens: [NSObjectProtocol] = []
    private weak var mentionCompletionObservedWindow: NSWindow?
    private var mentionCompletionRepositionIsScheduled = false
    private var activeInsertTextDepth = 0
    private var didChangeTextDuringActiveInsertText = false
    private var pendingUndoableAttachmentFileCleanup: [String: TextBoxAttachment] = [:]
    private var pendingAutomaticAttachmentFileCleanup: [String: TextBoxAttachment] = [:]
    private var suppressAutomaticAttachmentFileCleanup = false
    var mentionCompletionController: TextBoxMentionCompletionController {
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

    var isAttachmentPreviewShown: Bool {
        attachmentPreviewPopover?.isShown == true
    }

    deinit {
        mentionCompletionWarmupTask?.cancel()
        removeMentionCompletionWindowObservers()
        dismissMentionCompletions()
        removeAttachmentKeyDownMonitor()
        discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidatePendingAttachmentUploads()
            dismissMentionCompletions()
        } else {
            notifyMovedToWindowIfAttached()
            if mentionCompletionPanel?.isVisible == true {
                scheduleMentionCompletionPanelReposition()
            }
        }
        layer?.borderColor = textColor?.withAlphaComponent(0.24).cgColor
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshInlineAttachmentCells(
            font: font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshInlineAttachmentCells(
            font: font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
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
        let isOuterInsertText = activeInsertTextDepth == 0
        if isOuterInsertText {
            didChangeTextDuringActiveInsertText = false
        }
        activeInsertTextDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        activeInsertTextDepth = max(0, activeInsertTextDepth - 1)
        let didChangeTextWasHandled = didChangeTextDuringActiveInsertText
        if isOuterInsertText {
            didChangeTextDuringActiveInsertText = false
        }
        if didChangeTextWasHandled {
            flushAutomaticAttachmentFileCleanup()
        } else {
            didChangeText()
        }
        onMarkedTextStateChanged(hasMarkedText())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextStateChanged(hasMarkedText())
        // Marked text bypasses textDidChange. Schedule the TextBox measurement boundary so
        // AppKit coalesces rapid preedit updates before laying out TextKit storage.
        needsLayout = true
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextStateChanged(hasMarkedText())
    }

    override func didChangeText() {
        if activeInsertTextDepth > 0 {
            didChangeTextDuringActiveInsertText = true
        }
        isHandlingDidChangeText = true
        defer { isHandlingDidChangeText = false }
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true {
            reconcileInlineAttachmentRenderingAfterUndoRedo()
        }
        super.didChangeText()
        flushAutomaticAttachmentFileCleanup()
        refreshMentionCompletions()
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
        let attachments = inlineAttachments()
        if cleanupAttachmentFiles {
            cleanupDisposableAttachmentFiles(
                attachments,
                preservingActiveInlineAttachments: false
            )
        }
        discardAllInlineAttachmentRendering()
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

    /// Installs preserved attributed content into the text view.
    ///
    /// Pass `false` for `notifyingTextChange` only from representable construction paths where
    /// the owning panel already has the current draft state. That restores AppKit storage without
    /// running delegate or state-publication side effects during AppKit mounting.
    func installPreservedContent(_ content: NSAttributedString, notifyingTextChange: Bool = true) {
        installAttributedContent(content, notifyingTextChange: notifyingTextChange)
    }

    /// Installs a saved session draft into the text view.
    ///
    /// Pass `false` for `notifyingTextChange` only from representable construction paths where
    /// the owning panel already has the current draft state. That restores AppKit storage without
    /// running delegate or state-publication side effects during AppKit mounting.
    func installSessionDraft(_ draft: SessionTextBoxInputDraftSnapshot, notifyingTextChange: Bool = true) {
        installAttributedContent(
            attributedContent(from: draft),
            notifyingTextChange: notifyingTextChange
        )
    }

    private func installAttributedContent(_ content: NSAttributedString, notifyingTextChange: Bool) {
        invalidatePendingAttachmentUploads()
        dismissMentionCompletions()
        clearAttachmentFocus(dismissPreview: true)
        textStorage?.setAttributedString(content)
        refreshInlineAttachmentCells(
            font: font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
        typingAttributes = currentTextAttributes()
        setSelectedRange(NSRange(location: attributedString().length, length: 0))
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        recenterSingleLineTextContainer()
        if notifyingTextChange {
            didChangeText()
        } else {
            flushAutomaticAttachmentFileCleanup()
        }
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
        let appearance = effectiveAppearance
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var attachmentIDs: Set<UUID> = []
        var attachmentsByID: [UUID: [TextBoxInlineTextAttachment]] = [:]
        var focusedInlineAttachment: TextBoxInlineTextAttachment?
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            attachmentIDs.insert(attachment.textBoxAttachment.id)
            attachmentsByID[attachment.textBoxAttachment.id, default: []].append(attachment)
            let isFocused = isAttachmentFocused(at: range.location)
            attachment.refreshCell(
                font: font,
                foregroundColor: foregroundColor,
                isFocused: isFocused,
                renderer: inlineAttachmentRenderer,
                appearance: appearance,
                backingScale: backingScale
            )
            if isFocused {
                focusedInlineAttachment = attachment
            }
        }
        inlineAttachmentsByID = attachmentsByID
        inlineAttachmentRenderer.retainAttachments(withIDs: attachmentIDs)
        renderedFocusedInlineAttachment = focusedInlineAttachment
        normalizeTextBaselineOffsets()
        typingAttributes = currentTextAttributes(font: font, foregroundColor: foregroundColor)
        recenterSingleLineTextContainer()
    }

    func refreshInlineAttachmentFocus() {
        if !isFocusedAttachmentSelectionValid() {
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
        }
        let currentFocusedAttachment = focusedAttachmentCharacterIndex.flatMap {
            inlineTextAttachment(at: $0)
        }
        guard renderedFocusedInlineAttachment !== currentFocusedAttachment else { return }

        if let previouslyFocusedAttachment = renderedFocusedInlineAttachment {
            refreshInlineAttachmentCell(previouslyFocusedAttachment, isFocused: false)
        }
        if let currentFocusedAttachment {
            refreshInlineAttachmentCell(currentFocusedAttachment, isFocused: true)
        }
        renderedFocusedInlineAttachment = currentFocusedAttachment
    }

    private func refreshInlineAttachmentCell(forAttachmentID attachmentID: UUID) {
        guard let attachments = inlineAttachmentsByID[attachmentID] else { return }
        let font = font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize)
        let foregroundColor = textColor ?? .labelColor
        let appearance = effectiveAppearance
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        for attachment in attachments {
            attachment.refreshCell(
                font: font,
                foregroundColor: foregroundColor,
                isFocused: attachment.isFocused,
                renderer: inlineAttachmentRenderer,
                appearance: appearance,
                backingScale: backingScale
            )
        }
        // Placeholder and normalized thumbnails have identical geometry, so no layout pass is needed.
        needsDisplay = true
    }

    private func refreshInlineAttachmentCell(
        _ target: TextBoxInlineTextAttachment,
        isFocused: Bool
    ) {
        let attributed = attributedString()
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, stop in
            guard let attachment = value as? TextBoxInlineTextAttachment,
                  attachment === target else {
                return
            }
            attachment.refreshCell(
                font: font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
                foregroundColor: textColor ?? .labelColor,
                isFocused: isFocused,
                renderer: inlineAttachmentRenderer,
                appearance: effectiveAppearance,
                backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            )
            layoutManager?.invalidateDisplay(forCharacterRange: range)
            needsDisplay = true
            stop.pointee = true
        }
    }

    private func inlineTextAttachment(at characterIndex: Int) -> TextBoxInlineTextAttachment? {
        guard characterIndex >= 0,
              characterIndex < attributedString().length else {
            return nil
        }
        return attributedString().attribute(
            .attachment,
            at: characterIndex,
            effectiveRange: nil
        ) as? TextBoxInlineTextAttachment
    }

    func recenterSingleLineTextContainer() {
        guard let layoutManager,
              let textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let lineFragmentCount = visualLineFragmentCount()
        recenterSingleLineTextContainer(lineFragmentCount: lineFragmentCount)
    }

    fileprivate func recenterSingleLineTextContainer(lineFragmentCount: Int) {
        guard textContainer != nil else { return }

        let targetHeight = bounds.height > 0 ? bounds.height : TextBoxLayout.minimumTextHeight
        var targetVerticalInset: CGFloat
        if lineFragmentCount <= TextBoxLayout.minLines {
            let currentFont = font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize)
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
        guard !isReportingLayoutCompletion else { return }
        isReportingLayoutCompletion = true
        defer { isReportingLayoutCompletion = false }
        guard let layoutManager,
              let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let lineFragmentCount = visualLineFragmentCount()
        recenterSingleLineTextContainer(lineFragmentCount: lineFragmentCount)
        onLayoutCompleted(self, lineFragmentCount)
    }

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

    func handleInlineAttachmentCellClick(
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
              textBoxCommandShortcutKey(for: event) == "z" else {
            return super.performKeyEquivalent(with: event)
        }

        if flags.contains(.shift) {
            guard undoManager?.canRedo == true else { return true }
            undoManager?.redo()
            return true
        }

        guard undoManager?.canUndo == true else { return true }
        undoManager?.undo()
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

        if commandSelector == #selector(NSResponder.insertBacktab(_:)),
           let event = NSApp.currentEvent,
           handleConfiguredTextBoxShortcut(event) {
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
        let query = TextBoxMentionCompletionDetector.query(
            in: attributedString().string,
            selectedRange: selectedRange()
        )
        mentionCompletionController.refresh(
            for: query,
            rootDirectory: completionRootDirectory
        )
    }

    private func warmMentionCompletionIndexesIfNeeded() {
        let rootDirectory = completionRootDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = rootDirectory?.isEmpty == false ? rootDirectory : nil
        guard warmedMentionCompletionRootDirectory != cacheKey else { return }
        warmedMentionCompletionRootDirectory = cacheKey
        mentionCompletionWarmupTask?.cancel()
        mentionCompletionWarmupTask = Task {
            await TextBoxMentionIndexStore.shared.warmIndexes(rootDirectory: cacheKey)
        }
    }

    private func handleMentionCompletionKeyEvent(_ event: NSEvent) -> Bool {
        guard mentionCompletionController.isActive else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.option) else {
            return false
        }

        if flags.contains(.control) {
            guard let key = mentionCompletionControlNavigationKey(for: event) else { return false }
            switch key {
            case "p", "k":
                if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                    dismissMentionCompletions()
                    return false
                }
                // Only claim the navigation keys once there are rows to move through;
                // otherwise (active query still loading or zero hits) let them fall
                // through to normal text editing instead of being silently swallowed.
                guard mentionCompletionController.hasCurrentSuggestions else { return false }
                mentionCompletionController.moveSelection(delta: -1)
                return true
            case "n", "j":
                if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                    dismissMentionCompletions()
                    return false
                }
                guard mentionCompletionController.hasCurrentSuggestions else { return false }
                mentionCompletionController.moveSelection(delta: 1)
                return true
            default:
                return false
            }
        }

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: -1)
            return true
        case kVK_DownArrow:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !flags.contains(.shift) else { return false }
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            if shouldBypassMentionCompletionReturnAcceptance() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case kVK_Tab:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case kVK_Escape:
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.shouldShowPopover else { return false }
            dismissMentionCompletions()
            return true
        default:
            return false
        }
    }

    private func handleMentionCompletionCommand(_ commandSelector: Selector) -> Bool {
        guard mentionCompletionController.isActive else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.hasCurrentSuggestions else { return false }
            mentionCompletionController.moveSelection(delta: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            if shouldBypassMentionCompletionReturnAcceptance() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case #selector(NSResponder.insertTab(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            return acceptMentionCompletion()
        case #selector(NSResponder.cancelOperation(_:)):
            if shouldBypassHiddenMentionCompletionKeyboardInteraction() {
                dismissMentionCompletions()
                return false
            }
            guard mentionCompletionController.shouldShowPopover else { return false }
            dismissMentionCompletions()
            return true
        default:
            return false
        }
    }

    private func shouldBypassHiddenMentionCompletionKeyboardInteraction() -> Bool {
        guard let window else { return false }
        guard NSApp.isActive,
              window.isKeyWindow,
              window.firstResponder === self,
              mentionCompletionPanel?.isVisible == true else {
            return true
        }
        return false
    }

    private func shouldBypassMentionCompletionReturnAcceptance() -> Bool {
        guard let query = mentionCompletionController.activeQuery,
              query.kind == .skill,
              query.query.isEmpty else {
            return false
        }
        return true
    }

    @discardableResult
    private func acceptMentionCompletion(_ explicitSuggestion: TextBoxMentionSuggestion? = nil) -> Bool {
        guard mentionCompletionController.hasCurrentSuggestions,
              let query = mentionCompletionController.activeQuery,
              let suggestion = explicitSuggestion ?? mentionCompletionController.selectedSuggestion,
              explicitSuggestion == nil ||
                  mentionCompletionController.suggestions.contains(where: { $0.id == suggestion.id }),
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
        guard mentionCompletionController.shouldShowPopover else {
            dismissMentionCompletionPopoverOnly()
            return
        }
        guard NSApp.isActive,
              window?.firstResponder === self,
              let parentWindow = window,
              parentWindow.isKeyWindow,
              let anchorRect = mentionCompletionAnchorRect() else {
            dismissMentionCompletionPopoverOnly()
            return
        }
        updateMentionCompletionWindowObservers(for: parentWindow)

        let showsLoadingRow = mentionCompletionController.suggestions.isEmpty &&
            mentionCompletionController.isLoadingSuggestions
        let rowCount = showsLoadingRow ? 1 : mentionCompletionController.suggestions.count
        let maxVisibleRows = 12
        let visibleRows = min(rowCount, maxVisibleRows)
        let rowHeight: CGFloat = 25
        let contentSize = NSSize(
            width: 360,
            height: CGFloat(visibleRows) * rowHeight + 8
        )
        let host: TextBoxMentionCompletionContentView
        if let existingHost = mentionCompletionPanelHost {
            host = existingHost
        } else {
            host = TextBoxMentionCompletionContentView()
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            mentionCompletionPanelHost = host
        }
        host.update(
            suggestions: mentionCompletionController.suggestions,
            selectionIndex: mentionCompletionController.selectionIndex,
            searchTerm: mentionCompletionController.activeQuery?.query ?? "",
            isLoading: mentionCompletionController.isLoadingSuggestions,
            onSelect: { [weak self] suggestion in
                self?.window?.makeFirstResponder(self)
                self?.acceptMentionCompletion(suggestion)
            }
        )
        host.frame = NSRect(origin: .zero, size: contentSize)

        let panel = mentionCompletionPanel ?? makeMentionCompletionPanel(host: host)
        if panel.contentView !== host {
            panel.contentView = host
        }
        panel.setContentSize(contentSize)
        let targetOrigin = mentionCompletionPanelOrigin(
            anchorRect: anchorRect,
            contentSize: contentSize
        )
        if mentionCompletionPanelOriginNeedsUpdate(from: panel.frame.origin, to: targetOrigin) {
            panel.setFrameOrigin(targetOrigin)
        }

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func makeMentionCompletionPanel(
        host: TextBoxMentionCompletionContentView
    ) -> TextBoxMentionCompletionPanel {
        let panel = TextBoxMentionCompletionPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.textbox.mentionCompletionPanel")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = host
        mentionCompletionPanel = panel
        return panel
    }

    private func updateMentionCompletionWindowObservers(for parentWindow: NSWindow) {
        if mentionCompletionObservedWindow === parentWindow,
           !mentionCompletionWindowObserverTokens.isEmpty {
            return
        }

        removeMentionCompletionWindowObservers()
        mentionCompletionObservedWindow = parentWindow

        let notificationNames: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didResignKeyNotification
        ]
        let notificationCenter = NotificationCenter.default
        mentionCompletionWindowObserverTokens = notificationNames.map { notificationName in
            notificationCenter.addObserver(
                forName: notificationName,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleMentionCompletionPanelReposition()
            }
        }
    }

    private func removeMentionCompletionWindowObservers() {
        let notificationCenter = NotificationCenter.default
        for observerToken in mentionCompletionWindowObserverTokens {
            notificationCenter.removeObserver(observerToken)
        }
        mentionCompletionWindowObserverTokens = []
        mentionCompletionObservedWindow = nil
        mentionCompletionRepositionIsScheduled = false
    }

    private func scheduleMentionCompletionPanelReposition() {
        guard mentionCompletionPanel?.isVisible == true,
              !mentionCompletionRepositionIsScheduled else {
            return
        }
        mentionCompletionRepositionIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self,
                  self.mentionCompletionRepositionIsScheduled else {
                return
            }
            self.mentionCompletionRepositionIsScheduled = false
            self.repositionMentionCompletionPanelIfNeeded()
        }
    }

    private func repositionMentionCompletionPanelIfNeeded() {
        guard mentionCompletionController.shouldShowPopover,
              let panel = mentionCompletionPanel,
              panel.isVisible,
              NSApp.isActive,
              window?.firstResponder === self,
              let parentWindow = window,
              parentWindow.isKeyWindow,
              let anchorRect = mentionCompletionAnchorRect(),
              let contentSize = mentionCompletionPanelContentSize(panel),
              contentSize.width > 0,
              contentSize.height > 0 else {
            dismissMentionCompletionPopoverOnly()
            return
        }

        updateMentionCompletionWindowObservers(for: parentWindow)
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }

        let targetOrigin = mentionCompletionPanelOrigin(
            anchorRect: anchorRect,
            contentSize: contentSize
        )
        if mentionCompletionPanelOriginNeedsUpdate(from: panel.frame.origin, to: targetOrigin) {
            panel.setFrameOrigin(targetOrigin)
        }
    }

    private func mentionCompletionPanelContentSize(_ panel: TextBoxMentionCompletionPanel) -> NSSize? {
        if let contentView = panel.contentView {
            return contentView.bounds.size
        }
        return panel.contentRect(forFrameRect: panel.frame).size
    }

    private func mentionCompletionPanelOriginNeedsUpdate(
        from currentOrigin: NSPoint,
        to targetOrigin: NSPoint
    ) -> Bool {
        abs(currentOrigin.x - targetOrigin.x) > 0.5 ||
            abs(currentOrigin.y - targetOrigin.y) > 0.5
    }

    private func mentionCompletionPanelOrigin(
        anchorRect: NSRect,
        contentSize: NSSize
    ) -> NSPoint {
        let anchorInWindow = convert(anchorRect, to: nil)
        guard let window else {
            return .zero
        }
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        let screenFrame = window.screen?.visibleFrame ?? anchorOnScreen
        var x = anchorOnScreen.minX
        let gap: CGFloat = 4
        var y = anchorOnScreen.minY - contentSize.height - gap
        if y < screenFrame.minY + 8 {
            y = anchorOnScreen.maxY + gap
        }
        let maxX = screenFrame.maxX - contentSize.width - 8
        if x > maxX { x = max(screenFrame.minX + 8, maxX) }
        if x < screenFrame.minX + 8 { x = screenFrame.minX + 8 }
        return NSPoint(x: x, y: y)
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

        let queryCursor = mentionCompletionController.activeQuery.map { NSMaxRange($0.range) }
        let cursor = min(max(0, queryCursor ?? selectedRange().location), length)
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
        removeMentionCompletionWindowObservers()
        if let panel = mentionCompletionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        mentionCompletionPanel = nil
        mentionCompletionPanelHost = nil
    }

    func moveInsertionPointLeft() {
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

    func submitIfAllowed() {
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

    private func reconcileInlineAttachmentRenderingAfterUndoRedo() {
        refreshInlineAttachmentCells(
            font: font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
    }

#if DEBUG
    func debugSetMentionCompletionState(
        query: TextBoxMentionQuery?,
        suggestions: [TextBoxMentionSuggestion],
        rootDirectory: String? = nil,
        isLoading: Bool = false
    ) {
        mentionCompletionController.debugSetState(
            query: query,
            suggestions: suggestions,
            rootDirectory: rootDirectory,
            isLoading: isLoading
        )
    }

    func debugMentionSuggestionCount() -> Int {
        mentionCompletionController.debugSuggestionCount
    }

    func debugMentionSuggestionTitles() -> [String] {
        mentionCompletionController.debugSuggestionTitles
    }

    func debugMentionSuggestionsAreCurrent() -> Bool {
        mentionCompletionController.debugHasCurrentSuggestions
    }

    func debugMentionCompletionsShouldShowPopover() -> Bool {
        mentionCompletionController.debugShouldShowPopover
    }

    func debugMentionSelectionIndex() -> Int {
        mentionCompletionController.selectionIndex
    }

    func debugAcceptMentionCompletion() -> Bool {
        acceptMentionCompletion()
    }

    func debugAcceptMentionCompletion(suggestion: TextBoxMentionSuggestion) -> Bool {
        acceptMentionCompletion(suggestion)
    }

    func debugControlKey(for event: NSEvent) -> String? {
        controlKey(for: event)
    }

    func debugMentionCompletionControlNavigationKey(for event: NSEvent) -> String? {
        mentionCompletionControlNavigationKey(for: event)
    }

#endif

    func handleConfiguredTextBoxShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else {
            return false
        }
        if hasMarkedText(),
           shortcutRoutingShouldBypassForPrintableOptionText(event: event) {
            return false
        }
        if textBoxShortcut(event, matches: .focusTextBoxInput) {
            onToggleFocus()
            return true
        }
        if textBoxShortcut(event, matches: .cycleTextBoxSubmitAction) {
            guard !hasMarkedText() else { return false }
            onCycleSubmitAction()
            return true
        }
        if textBoxShortcut(event, matches: .attachTextBoxFile) {
            onChooseFiles()
            return true
        }
        return false
    }

    private func textBoxShortcut(_ event: NSEvent, matches action: KeyboardShortcutSettings.Action) -> Bool {
        guard KeyboardShortcutSettings.shortcut(for: action).matches(event: event) else {
            return false
        }
        return AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
    }

    private func handleStandardEditShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }

        switch textBoxCommandShortcutKey(for: event) {
        case "c":
            copy(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "v":
            paste(nil)
            return true
        default:
            return false
        }
    }

    func deleteAttachment(at characterIndex: Int) {
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

    func moveInsertionPointRight() {
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

    func selectAttachment(at characterIndex: Int) {
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

    func focusedAttachment() -> (attachment: TextBoxAttachment, characterIndex: Int)? {
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

    func attachment(at characterIndex: Int) -> TextBoxAttachment? {
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

    func toggleAttachmentPreview(
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

    func showAttachmentPreview(
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

    func dismissAttachmentPreview() {
        attachmentPreviewPopover?.performClose(nil)
        attachmentPreviewPopover = nil
        attachmentPreviewCharacterIndex = nil
    }

    func clearAttachmentFocus(dismissPreview shouldDismissPreview: Bool) {
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

        let removedInlineAttachments = inlineTextAttachments(in: range)
        let removedAttachments = removedInlineAttachments.map(\.textBoxAttachment)
        discardInlineAttachmentRendering(for: removedInlineAttachments)
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
        inlineTextAttachments(in: range).map(\.textBoxAttachment)
    }

    private func inlineTextAttachments(in range: NSRange) -> [TextBoxInlineTextAttachment] {
        guard isValidSelectedRange(range),
              range.length > 0 else {
            return []
        }
        var result: [TextBoxInlineTextAttachment] = []
        attributedString().enumerateAttribute(.attachment, in: range, options: []) { value, _, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            result.append(attachment)
        }
        return result
    }

    private func queueAutomaticAttachmentFileCleanup(in range: NSRange) {
        guard !suppressAutomaticAttachmentFileCleanup else { return }
        let removedInlineAttachments = inlineTextAttachments(in: range)
        guard !removedInlineAttachments.isEmpty else { return }
        discardInlineAttachmentRendering(for: removedInlineAttachments)
        let removedAttachments = removedInlineAttachments.map(\.textBoxAttachment)
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

    private func discardInlineAttachmentRendering(
        for removedAttachments: [TextBoxInlineTextAttachment]
    ) {
        let removedByID = Dictionary(
            grouping: removedAttachments,
            by: \.textBoxAttachment.id
        )
        var attachmentIDsWithoutOccurrences: Set<UUID> = []
        for (attachmentID, removedOccurrences) in removedByID {
            let removedIdentities = Set(removedOccurrences.map(ObjectIdentifier.init))
            guard var remainingOccurrences = inlineAttachmentsByID[attachmentID] else {
                continue
            }
            remainingOccurrences.removeAll {
                removedIdentities.contains(ObjectIdentifier($0))
            }
            if remainingOccurrences.isEmpty {
                inlineAttachmentsByID.removeValue(forKey: attachmentID)
                attachmentIDsWithoutOccurrences.insert(attachmentID)
            } else {
                inlineAttachmentsByID[attachmentID] = remainingOccurrences
            }
        }
        inlineAttachmentRendererStorage?.removeAttachments(
            withIDs: attachmentIDsWithoutOccurrences
        )
    }

    private func discardAllInlineAttachmentRendering() {
        inlineAttachmentsByID.removeAll()
        inlineAttachmentRendererStorage?.retainAttachments(withIDs: [])
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

    func currentTextAttributes(
        font explicitFont: NSFont? = nil,
        foregroundColor explicitForegroundColor: NSColor? = nil
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: explicitFont ?? font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: explicitForegroundColor ?? textColor ?? .labelColor,
            .baselineOffset: textBaselineOffsetForCurrentContent()
        ]
    }

    func inlineAttachmentAttributedString(for attachment: TextBoxAttachment) -> NSAttributedString {
        let inlineAttachment = TextBoxInlineTextAttachment(
            attachment: attachment,
            font: font ?? GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor,
            renderer: inlineAttachmentRenderer,
            appearance: effectiveAppearance,
            backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )
        inlineAttachmentsByID[attachment.id, default: []].append(inlineAttachment)
        let attributed = NSMutableAttributedString(
            attachment: inlineAttachment
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
        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(ghosttyTemporaryURLs)
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
        physicalControlKey(for: event) ?? event.charactersIgnoringModifiers?.lowercased()
    }

    private func mentionCompletionControlNavigationKey(for event: NSEvent) -> String? {
        let normalizedKey = KeyboardLayout.normalizedCharacters(for: event).lowercased()
        if normalizedKey.count == 1, normalizedKey.allSatisfy(\.isASCII) {
            return normalizedKey
        }
        return controlKey(for: event)
    }

    private func physicalControlKey(for event: NSEvent) -> String? {
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
            return nil
        }
    }
}
