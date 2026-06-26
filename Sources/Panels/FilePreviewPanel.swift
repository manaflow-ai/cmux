import AppKit
import AVKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxWorkspaces
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Localized titles for the file-external-open menus, resolved against the app
/// bundle (which owns the catalog keys).
///
/// A value type instantiated where the titles are needed: each `init()`
/// re-resolves `String(localized:)`, so a locale change is reflected on the next
/// use, matching the former per-call resolution before this was a value type.
struct FileExternalOpenText {
    let openWithMenu: String
    let openExternally: String
    let revealInFinder: String
    /// `printf`-style format with a single `%@` for the application name.
    let openInApplicationFormat: String

    init() {
        openWithMenu = String(localized: "filePreview.openWith.menu", defaultValue: "Open With")
        openExternally = String(localized: "filePreview.openExternally", defaultValue: "Open Externally")
        revealInFinder = String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder")
        openInApplicationFormat = String(localized: "filePreview.openInApplication", defaultValue: "Open in %@")
    }

    func openInApplication(_ applicationName: String) -> String {
        String(format: openInApplicationFormat, applicationName)
    }
}

extension FileExternalOpenMenuActionTarget {
    /// Process-wide retained `@objc` target for the file-external-open menus.
    /// `NSMenuItem.target` is a weak reference, so this single instance is
    /// composed app-side (the composition root) and held for the process
    /// lifetime so it outlives every menu its items belong to. Mirrors
    /// `FilePreviewDragRegistry.shared` below.
    static let shared = FileExternalOpenMenuActionTarget()
}

extension FileExternalOpenMenuBuilder {
    /// App-side file-external-open menu builder. Resolves its localized titles
    /// freshly on each access (so a locale change is reflected, matching the
    /// former per-`makeMenu` `String(localized:)` resolution) and wires the
    /// produced items to the retained ``FileExternalOpenMenuActionTarget/shared``.
    /// Composed here, app-side, because the localized titles bind to the app
    /// bundle and the scattered SwiftUI menu views share no common constructor
    /// to inject a builder through.
    static var app: FileExternalOpenMenuBuilder {
        let text = FileExternalOpenText()
        return FileExternalOpenMenuBuilder(
            strings: FileExternalOpenMenuStrings(
                openWithMenu: text.openWithMenu,
                openExternally: text.openExternally,
                revealInFinder: text.revealInFinder,
                openInApplicationFormat: text.openInApplicationFormat
            ),
            target: .shared
        )
    }
}

enum FileExternalOpenMenuStyle {
    case header
    case chrome

    var buttonSize: CGSize {
        switch self {
        case .header:
            return CGSize(width: 18, height: 18)
        case .chrome:
            return CGSize(width: 40, height: 40)
        }
    }
}

struct FileExternalOpenMenu: View {
    let fileURL: URL
    var isDisabled = false
    var style: FileExternalOpenMenuStyle = .header

    @State private var resolvedApplications: [FileExternalOpenApplication] = []

    var body: some View {
        let applications = resolvedApplications
        let primaryApplication = primaryApplication(in: applications)
        let otherApplications = applications.filter { application in
            application.id != primaryApplication?.id
        }
        let helpText = helpText(for: primaryApplication)

        Group {
            switch style {
            case .header:
                FileExternalOpenHeaderMenuButton(
                    fileURL: fileURL,
                    primaryApplication: primaryApplication,
                    otherApplications: otherApplications,
                    helpText: helpText,
                    isDisabled: isDisabled
                )
            case .chrome:
                Button {
                    presentMenu(
                        applications: applications,
                        currentPrimaryApplication: primaryApplication,
                        otherApplications: otherApplications
                    )
                } label: {
                    label
                }
                .contentShape(Rectangle())
                .disabled(isDisabled)
                .help(helpText)
                .accessibilityLabel(helpText)
            }
        }
        .task(id: fileURL) {
            await refreshApplications()
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .header:
            PanelHeaderIconGlyph(systemName: "square.and.arrow.up")
        case .chrome:
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: style.buttonSize.width, height: style.buttonSize.height)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
    }

    private func primaryApplication(in applications: [FileExternalOpenApplication]) -> FileExternalOpenApplication? {
        applications.first { $0.isDefault } ?? applications.first
    }

    private func helpText(for primaryApplication: FileExternalOpenApplication?) -> String {
        if let primaryApplication {
            return openInTitle(primaryApplication.displayName)
        }
        return FileExternalOpenText().openExternally
    }

    private func openInTitle(_ applicationName: String) -> String {
        FileExternalOpenText().openInApplication(applicationName)
    }

    @MainActor
    private func refreshApplications() async {
        resolvedApplications = []
        let url = fileURL
        let applications = await Task.detached(priority: .userInitiated) {
            FileExternalOpenApplicationResolver.live.applications(for: url)
        }.value
        guard !Task.isCancelled else { return }
        resolvedApplications = applications
    }

    private func presentMenu(
        applications: [FileExternalOpenApplication],
        currentPrimaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) {
        guard !isDisabled else { return }
        let menuApplications: [FileExternalOpenApplication]
        if applications.isEmpty {
            menuApplications = FileExternalOpenApplicationResolver.live.applications(for: fileURL)
        } else {
            menuApplications = applications
        }
        let primary = primaryApplication(in: menuApplications) ?? currentPrimaryApplication
        let others = menuApplications.filter { application in
            application.id != primary?.id
        } + otherApplications.filter { application in
            application.id != primary?.id
                && !menuApplications.contains(where: { $0.id == application.id })
        }
        let menu = makeMenu(primaryApplication: primary, otherApplications: others)
        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil as NSMenuItem?, at: point, in: contentView)
        } else {
            menu.popUp(positioning: nil as NSMenuItem?, at: NSEvent.mouseLocation, in: nil as NSView?)
        }
    }

    private func makeMenu(
        primaryApplication: FileExternalOpenApplication?,
        otherApplications: [FileExternalOpenApplication]
    ) -> NSMenu {
        FileExternalOpenMenuBuilder.app.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: otherApplications
        )
    }
}

private struct FileExternalOpenHeaderMenuButton: View {
    let fileURL: URL
    let primaryApplication: FileExternalOpenApplication?
    let otherApplications: [FileExternalOpenApplication]
    let helpText: String
    let isDisabled: Bool

    var body: some View {
        Button(action: presentMenu) {
            PanelHeaderIconGlyph(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private func presentMenu() {
        let menu = makeMenu()
        if let event = NSApp.currentEvent,
           let contentView = event.window?.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil as NSMenuItem?, at: point, in: contentView)
            return
        }

        guard let contentView = NSApp.keyWindow?.contentView else { return }
        menu.popUp(
            positioning: nil as NSMenuItem?,
            at: NSPoint(x: contentView.bounds.maxX - 24, y: contentView.bounds.maxY - 32),
            in: contentView
        )
    }

    private func makeMenu() -> NSMenu {
        FileExternalOpenMenuBuilder.app.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: otherApplications
        )
    }
}

@MainActor
final class FilePreviewPanel: Panel, ObservableObject, FilePreviewTextEditingPanel {
    let id: UUID
    let panelType: PanelType = .filePreview
    let filePath: String
    private(set) var workspaceId: UUID
    @Published private(set) var displayTitle: String
    @Published private(set) var displayIcon: String?
    @Published private(set) var isFileUnavailable = false
    @Published private(set) var textContent = ""
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var focusFlashToken = 0
    @Published private(set) var previewMode: FilePreviewMode

    let nativeViewSessions = FilePreviewNativeViewSessions()

    private var originalTextContent = ""
    private var textEncoding: String.Encoding = .utf8
    private var previewModeGeneration = 0
    private var textLoadGeneration = 0
    private var saveGeneration = 0
    private var activeSaveGeneration: Int?
    private weak var textView: NSTextView?
    private let focusCoordinator: FilePreviewFocusCoordinator
    private let textLoader: @Sendable (URL) async -> FilePreviewTextLoader.Result

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    init(
        workspaceId: UUID,
        filePath: String,
        textLoader: @escaping @Sendable (URL) async -> FilePreviewTextLoader.Result = { url in
            await FilePreviewTextLoader().load(url: url)
        }
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = URL(fileURLWithPath: filePath).lastPathComponent
        self.textLoader = textLoader
        let fileURL = URL(fileURLWithPath: filePath)
        let initialPreviewMode = FilePreviewKindResolver().initialMode(for: fileURL)
        self.previewMode = initialPreviewMode
        self.displayIcon = initialPreviewMode.iconName
        self.focusCoordinator = FilePreviewFocusCoordinator(
            preferredIntent: Self.defaultFocusIntent(for: initialPreviewMode)
        )

        prepareContentForPreviewMode()
        resolvePreviewModeIfNeeded(for: fileURL)
    }

    func focus() {
        _ = restoreFocusIntent(preferredFocusIntentForActivation())
    }

    func unfocus() {
        // No-op. AppKit resigns the text view when another panel becomes first responder.
    }

    func close() {
        nativeViewSessions.closeAll()
        textView = nil
        focusCoordinator.unregisterAll()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationDefaultsToggle.paneFlash.isEnabled() else { return }
        focusFlashToken += 1
    }

    func attachTextView(_ textView: NSTextView) {
        self.textView = textView
        focusCoordinator.register(root: textView, primaryResponder: textView, intent: .textEditor)
    }

    func handleDroppedFileURLsAsText(_ urls: [URL]) -> Bool {
        guard previewMode == .text, let textView else { return false }
        let text = TerminalImageTransferPlanner.insertedText(forFileURLs: urls)
        guard !text.isEmpty else { return false }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
        updateTextContent(textView.string)
        return true
    }

    func retryPendingFocus() {
        focusCoordinator.fulfillPendingFocusIfNeeded()
    }

    func attachPDFPreview(root: NSView, primaryResponder: NSView) {
        attachPreviewFocus(root: root, primaryResponder: primaryResponder, intent: .pdfCanvas)
    }

    func attachPreviewFocus(
        root: NSView,
        primaryResponder: NSView,
        intent: FilePreviewPanelFocusIntent
    ) {
        focusCoordinator.register(root: root, primaryResponder: primaryResponder, intent: intent)
    }

    func noteFilePreviewFocusIntent(_ intent: FilePreviewPanelFocusIntent) {
        focusCoordinator.notePreferredIntent(intent)
    }

    func currentFilePreviewFocusIntent(in window: NSWindow?) -> FilePreviewPanelFocusIntent? {
        guard let window,
              let responder = window.firstResponder else { return nil }
        return focusCoordinator.ownedIntent(for: responder, in: window)
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        if let window,
           let responder = window.firstResponder,
           let intent = ownedFocusIntent(for: responder, in: window) {
            return intent
        }
        return preferredFocusIntentForActivation()
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .filePreview(focusCoordinator.preferredIntent)
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        if case .filePreview(let filePreviewIntent) = intent {
            focusCoordinator.notePreferredIntent(filePreviewIntent)
        }
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        let filePreviewIntent: FilePreviewPanelFocusIntent
        switch intent {
        case .filePreview(let target):
            filePreviewIntent = target
        case .panel:
            filePreviewIntent = focusCoordinator.preferredIntent
        case .terminal, .browser, .project:
            return false
        }
        return focusCoordinator.focus(filePreviewIntent)
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        if let intent = focusCoordinator.ownedIntent(for: responder, in: window) {
            return .filePreview(intent)
        }
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder,
              ownedFocusIntent(for: responder, in: window) == intent else {
            return false
        }
        return window.makeFirstResponder(nil)
    }

    func updateTextContent(_ nextContent: String) {
        guard textContent != nextContent else { return }
        textContent = nextContent
        isDirty = nextContent != originalTextContent
    }

    private func prepareContentForPreviewMode() {
        if previewMode == .text {
            loadTextContent(replacingDirtyContent: false)
        } else {
            isFileUnavailable = !FileManager.default.fileExists(atPath: filePath)
        }
    }

    private func resolvePreviewModeIfNeeded(for fileURL: URL) {
        let initialMode = previewMode
        let initialIcon = displayIcon
        previewModeGeneration += 1
        let generation = previewModeGeneration

        Task { [weak self, fileURL, initialMode, initialIcon, generation] in
            let resolvedMode = await FilePreviewKindResolver().resolveMode(url: fileURL)
            guard let self, self.previewModeGeneration == generation else { return }
            let resolvedIcon = resolvedMode.iconName
            guard resolvedMode != initialMode || resolvedIcon != initialIcon else { return }
            self.applyResolvedPreviewMode(resolvedMode)
        }
    }

    private func applyResolvedPreviewMode(_ mode: FilePreviewMode) {
        guard previewMode != mode else { return }
        if mode != .text {
            textLoadGeneration += 1
        }
        previewMode = mode
        displayIcon = mode.iconName
        focusCoordinator.notePreferredIntent(Self.defaultFocusIntent(for: mode))
        nativeViewSessions.closeInactive(except: mode)
        prepareContentForPreviewMode()
    }

    @discardableResult
    func loadTextContent(replacingDirtyContent: Bool = true) -> Task<Void, Never> {
        guard previewMode == .text else {
            return Task {}
        }
        textLoadGeneration += 1
        let generation = textLoadGeneration
        let fileURL = fileURL
        let textLoader = textLoader

        return Task { [weak self, fileURL, generation, replacingDirtyContent, textLoader] in
            let result = await textLoader(fileURL)
            guard let self,
                  self.textLoadGeneration == generation,
                  self.previewMode == .text else { return }
            self.applyTextLoadResult(result, replacingDirtyContent: replacingDirtyContent)
        }
    }

    private func applyTextLoadResult(
        _ result: FilePreviewTextLoader.Result,
        replacingDirtyContent: Bool
    ) {
        switch result {
        case .unavailable:
            guard replacingDirtyContent || !isDirty else {
                isFileUnavailable = true
                return
            }
            textContent = ""
            originalTextContent = ""
            isDirty = false
            isFileUnavailable = true
            return
        case .loaded(let content, let encoding):
            if !replacingDirtyContent && isDirty {
                originalTextContent = content
                textEncoding = encoding
                isFileUnavailable = false
                return
            }
            textContent = content
            originalTextContent = content
            textEncoding = encoding
            isDirty = false
            isFileUnavailable = false
        }
    }

    @discardableResult
    func saveTextContent() -> Task<Void, Never>? {
        guard previewMode == .text else { return nil }
        guard !isSaving else { return nil }
        let currentContent = textView?.string ?? textContent
        guard currentContent != originalTextContent else {
            textContent = currentContent
            isDirty = false
            return nil
        }

        textLoadGeneration += 1
        saveGeneration += 1
        let generation = saveGeneration
        textContent = currentContent
        isSaving = true
        activeSaveGeneration = generation
        let fileURL = fileURL
        let encoding = textEncoding
        return Task { [weak self, currentContent, fileURL, encoding, generation] in
            let result = await FilePreviewTextSaver().save(content: currentContent, to: fileURL, encoding: encoding)
            guard let self, self.activeSaveGeneration == generation else { return }
            self.activeSaveGeneration = nil
            self.isSaving = false
            switch result {
            case .saved:
                self.originalTextContent = currentContent
                self.isDirty = self.textContent != currentContent
                self.isFileUnavailable = false
            case .failed(let fileExists):
                self.isFileUnavailable = !fileExists
            }
        }
    }

    private static func defaultFocusIntent(for mode: FilePreviewMode) -> FilePreviewPanelFocusIntent {
        switch mode {
        case .text:
            return .textEditor
        case .pdf:
            return .pdfCanvas
        case .image:
            return .imageCanvas
        case .media:
            return .mediaPlayer
        case .quickLook:
            return .quickLook
        }
    }
}

struct FilePreviewPanelView: View {
    @ObservedObject var panel: FilePreviewPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity = 0.0
    @State private var focusFlashAnimationGeneration = 0
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled

    private var themeForegroundColor: NSColor {
        appearance.foregroundColor
    }

    private var contentBackgroundColor: NSColor {
        appearance.contentBackgroundColor
    }

    var body: some View {
        VStack(spacing: 0) {
            if panel.previewMode != .pdf {
                header
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: contentBackgroundColor))
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .overlay {
            if isVisibleInUI {
                FilePreviewPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
    }

    private var header: some View {
        PanelFilePathHeader(
            iconSystemName: panel.displayIcon ?? "doc.viewfinder",
            filePath: panel.filePath,
            foregroundColor: themeForegroundColor
        ) {
            if panel.previewMode == .text {
                PanelHeaderIconButton(
                    systemName: "arrow.counterclockwise",
                    label: String(localized: "filePreview.revert", defaultValue: "Revert"),
                    isDisabled: !panel.isDirty,
                    action: { panel.loadTextContent() }
                )

                PanelHeaderIconButton(
                    systemName: "square.and.arrow.down",
                    label: String(localized: "filePreview.save", defaultValue: "Save"),
                    isDisabled: !panel.isDirty || panel.isSaving,
                    action: { panel.saveTextContent() }
                )
            }

            FileExternalOpenMenu(fileURL: panel.fileURL, isDisabled: panel.isFileUnavailable)
        }
    }

    @ViewBuilder
    private var content: some View {
        if panel.isFileUnavailable {
            fileUnavailableView
        } else {
            switch panel.previewMode {
            case .text:
                FilePreviewTextEditor(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    themeBackgroundColor: contentBackgroundColor,
                    themeForegroundColor: themeForegroundColor,
                    drawsBackground: appearance.drawsContentBackground,
                    wordWrap: fileEditorWordWrap
                )
            case .pdf:
                FilePreviewPDFView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            case .image:
                FilePreviewImageView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            case .media:
                FilePreviewMediaView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            case .quickLook:
                QuickLookPreviewView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            }
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(localized: "filePreview.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "filePreview.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

private struct FilePreviewPDFView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewPDFContainerView {
        panel.nativeViewSessions.pdf.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: FilePreviewPDFContainerView, context: Context) {
        panel.nativeViewSessions.pdf.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

final class FilePreviewPDFChromeHostView: NSView {
    var interactiveOverlayViews: [NSView] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        for overlayView in interactiveOverlayViews.reversed() where !overlayView.isHidden {
            let convertedPoint = convert(point, to: overlayView)
            if let hitView = interactiveHit(in: overlayView, at: convertedPoint) {
                return hitView
            }
        }
        return nil
    }

    private func interactiveHit(in view: NSView, at point: NSPoint) -> NSView? {
        guard !view.isHidden, view.bounds.contains(point) else { return nil }
        for subview in view.subviews.reversed() {
            let convertedPoint = view.convert(point, to: subview)
            if let hitView = interactiveHit(in: subview, at: convertedPoint) {
                return hitView
            }
        }
        return view is NSControl || view is FilePreviewPDFChromeHostingView ? view : nil
    }
}

final class FilePreviewPDFChromeHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class FilePreviewPDFThumbnailSidebarView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    private enum Metrics {
        static let thumbnailHeight = FilePreviewPDFSizing.thumbnailMaximumSize.height
        static let labelHeight: CGFloat = 22
        static let itemSpacing: CGFloat = 12
        static let verticalInset: CGFloat = 24
    }

    private let scrollView = NSScrollView()
    private let collectionView = FilePreviewPDFThumbnailCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var document: PDFDocument?
    private var isApplyingSelection = false
    private var selectedPageIndex: Int?
    private var selectionIsActive = false

    var onSelectPage: ((PDFPage) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onPageNavigation: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateItemSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateItemSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateItemSize()
    }

    func setDocument(_ document: PDFDocument?) {
        self.document = document
        selectedPageIndex = nil
        collectionView.reloadData()
        selectPage(at: 0, scrollToVisible: false)
    }

    func selectPage(at pageIndex: Int, scrollToVisible: Bool) {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else {
            selectedPageIndex = nil
            collectionView.deselectAll(nil)
            return
        }

        isApplyingSelection = true
        let previousPageIndex = selectedPageIndex
        selectedPageIndex = pageIndex
        let indexPath = IndexPath(item: pageIndex, section: 0)
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [indexPath], scrollPosition: scrollToVisible ? .centeredVertically : [])
        let reloadIndexPaths = [previousPageIndex, selectedPageIndex]
            .compactMap { $0 }
            .filter { $0 >= 0 && $0 < document.pageCount }
            .map { IndexPath(item: $0, section: 0) }
        if !reloadIndexPaths.isEmpty {
            collectionView.reloadItems(at: Set(reloadIndexPaths))
        }
        isApplyingSelection = false
    }

    func reloadPage(at pageIndex: Int) {
        guard let document, pageIndex >= 0, pageIndex < document.pageCount else { return }
        collectionView.reloadItems(at: [IndexPath(item: pageIndex, section: 0)])
    }

    func setSelectionActive(_ isActive: Bool) {
        guard selectionIsActive != isActive else { return }
        selectionIsActive = isActive
        for item in collectionView.visibleItems() {
            (item as? FilePreviewPDFThumbnailItem)?.isSelectionActiveForPreview = isActive
        }
    }

    func preferredSidebarWidth() -> CGFloat {
        FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)
    }

    func focusResponder() -> NSView {
        collectionView
    }

    private func setupView() {
        flowLayout.scrollDirection = .vertical
        flowLayout.minimumLineSpacing = Metrics.itemSpacing
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = NSEdgeInsets(
            top: Metrics.verticalInset,
            left: 0,
            bottom: Metrics.verticalInset,
            right: 0
        )

        collectionView.collectionViewLayout = flowLayout
        collectionView.autoresizingMask = [.width]
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.onFocusChanged = { [weak self] isActive in
            self?.onFocusChanged?(isActive)
        }
        collectionView.onPageNavigation = { [weak self] delta in
            self?.onPageNavigation?(delta)
        }
        collectionView.onPrimaryClickItem = { [weak self] pageIndex in
            self?.selectPageFromPrimaryClick(at: pageIndex)
        }
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(
            FilePreviewPDFThumbnailItem.self,
            forItemWithIdentifier: FilePreviewPDFThumbnailItem.reuseIdentifier
        )

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateItemSize() {
        let itemWidth = thumbnailItemWidth()
        if abs(collectionView.frame.width - itemWidth) > 0.5 {
            collectionView.setFrameSize(NSSize(width: itemWidth, height: collectionView.frame.height))
        }
        let nextSize = thumbnailItemSize(width: itemWidth)
        guard flowLayout.itemSize != nextSize else { return }
        flowLayout.itemSize = nextSize
        flowLayout.invalidateLayout()
    }

    private func thumbnailItemWidth() -> CGFloat {
        let contentWidth = scrollView.contentView.bounds.width
        let scrollWidth = scrollView.bounds.width
        let fallbackWidth = bounds.width
        return max(1, contentWidth, scrollWidth, fallbackWidth)
    }

    private func thumbnailItemSize(width: CGFloat) -> NSSize {
        NSSize(
            width: max(1, width),
            height: Metrics.thumbnailHeight + Metrics.labelHeight + 10
        )
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        document?.pageCount ?? 0
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: FilePreviewPDFThumbnailItem.reuseIdentifier,
            for: indexPath
        ) as? FilePreviewPDFThumbnailItem ?? FilePreviewPDFThumbnailItem()
        let page = document?.page(at: indexPath.item)
        item.configure(
            page: page,
            pageNumber: indexPath.item + 1,
            isSelectedForPreview: indexPath.item == selectedPageIndex,
            isSelectionActiveForPreview: selectionIsActive
        )
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelection,
              let pageIndex = indexPaths.first?.item,
              let page = document?.page(at: pageIndex) else { return }
        window?.makeFirstResponder(collectionView)
        setSelectionActive(true)
        onSelectPage?(page)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        thumbnailItemSize(width: thumbnailItemWidth())
    }

    private func selectPageFromPrimaryClick(at pageIndex: Int) {
        guard let document,
              pageIndex >= 0,
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        window?.makeFirstResponder(collectionView)
        setSelectionActive(true)
        selectPage(at: pageIndex, scrollToVisible: false)
        onSelectPage?(page)
    }
}

private final class FilePreviewPDFOutlineView: NSOutlineView {
    var onFocusChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private final class FilePreviewPDFThumbnailItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("filePreviewPDFThumbnailItem")

    private var thumbnailItemView: FilePreviewPDFThumbnailItemView? {
        view as? FilePreviewPDFThumbnailItemView
    }

    override var isSelected: Bool {
        didSet {
            thumbnailItemView?.isSelectedForPreview = isSelected
        }
    }

    var isSelectionActiveForPreview = false {
        didSet {
            thumbnailItemView?.isSelectionActiveForPreview = isSelectionActiveForPreview
        }
    }

    override func loadView() {
        view = FilePreviewPDFThumbnailItemView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailItemView?.configure(image: nil, pageNumber: "")
        thumbnailItemView?.isSelectedForPreview = false
        thumbnailItemView?.isSelectionActiveForPreview = false
    }

    func configure(
        page: PDFPage?,
        pageNumber: Int,
        isSelectedForPreview: Bool,
        isSelectionActiveForPreview: Bool
    ) {
        let thumbnail = page?.thumbnail(of: FilePreviewPDFSizing.thumbnailMaximumSize, for: .cropBox)
        thumbnailItemView?.configure(image: thumbnail, pageNumber: "\(pageNumber)")
        thumbnailItemView?.isSelectedForPreview = isSelectedForPreview
        thumbnailItemView?.isSelectionActiveForPreview = isSelectionActiveForPreview
    }
}

private final class FilePreviewPDFThumbnailItemView: NSView {
    private enum Metrics {
        static let selectionHorizontalInset: CGFloat = 8
        static let thumbnailHorizontalInset: CGFloat = 4
    }

    private let selectionView = NSView()
    private let imageView = NSImageView()
    private let pageLabel = NSTextField(labelWithString: "")

    var isSelectedForPreview = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    var isSelectionActiveForPreview = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(image: NSImage?, pageNumber: String) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        imageView.image = image
        pageLabel.stringValue = pageNumber
    }

    private func setupView() {
        wantsLayer = true

        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = 10
        selectionView.layer?.masksToBounds = true
        selectionView.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        pageLabel.alignment = .center
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        pageLabel.lineBreakMode = .byTruncatingTail
        pageLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionView)
        addSubview(imageView)
        addSubview(pageLabel)

        NSLayoutConstraint.activate([
            selectionView.topAnchor.constraint(equalTo: topAnchor),
            selectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.selectionHorizontalInset),
            selectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.selectionHorizontalInset),
            selectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: selectionView.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: selectionView.leadingAnchor, constant: Metrics.thumbnailHorizontalInset),
            imageView.trailingAnchor.constraint(equalTo: selectionView.trailingAnchor, constant: -Metrics.thumbnailHorizontalInset),
            imageView.heightAnchor.constraint(equalToConstant: 106),

            pageLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            pageLabel.centerXAnchor.constraint(equalTo: selectionView.centerXAnchor),
            pageLabel.bottomAnchor.constraint(lessThanOrEqualTo: selectionView.bottomAnchor, constant: -5),
        ])
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        if isSelectedForPreview {
            selectionView.layer?.backgroundColor = (isSelectionActiveForPreview
                ? NSColor.selectedContentBackgroundColor
                : NSColor.unemphasizedSelectedContentBackgroundColor
            ).cgColor
        } else {
            selectionView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        pageLabel.textColor = isSelectedForPreview
            ? (isSelectionActiveForPreview ? .white : .labelColor)
            : .secondaryLabelColor
    }
}

final class FilePreviewPDFContainerView: NSView, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Metrics {
        static let defaultSidebarWidth = FilePreviewPDFSizing.defaultSidebarWidth
        static let minimumSidebarWidth = FilePreviewPDFSizing.minimumSidebarWidth
        static let maximumSidebarWidth = FilePreviewPDFSizing.maximumSidebarWidth
        static let floatingChromeHeight: CGFloat = 40
        static let floatingControlsWidth: CGFloat = 344
        static let floatingChromeCornerRadius: CGFloat = 20
    }

    private let splitView = NSSplitView()
    private let sidebarHost = NSVisualEffectView()
    private let contentHost = NSView()
    private let chromeHost = FilePreviewPDFChromeHostView()
    private let pdfView = FilePreviewMagnifyingPDFView()
    private let thumbnailView = FilePreviewPDFThumbnailSidebarView()
    private let outlineScrollView = NSScrollView()
    private let outlineView = FilePreviewPDFOutlineView()
    private let outlinePlaceholder = NSTextField(wrappingLabelWithString: "")
    private let sidebarChromeHost = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))
    private let zoomChromeHost = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private weak var panel: FilePreviewPanel?
    private var currentURL: URL?
    private var outlineRoot: PDFOutline?
    private var sidebarMode: FilePreviewPDFSidebarMode = .thumbnails
    private var displayMode: FilePreviewPDFDisplayMode = .continuousScroll
    private var isSidebarVisible = true
    private var chromeStyleVariant = FilePreviewPDFChromeStyleVariant.current()
    private var didSetInitialSidebarWidth = false
    private var lastSidebarWidth = Metrics.defaultSidebarWidth
    private var didUserResizeSidebar = false
    private var isApplyingSidebarWidth = false
    private var pendingSidebarResizeSnapshot: FilePreviewPDFViewportSnapshot?
    private var suppressPDFPageChangeNotifications = false
    private var pdfResizeSequence = 0
    private var activePDFResizeID: Int?
    private var activePDFRegion: FilePreviewPanelFocusIntent?
    private weak var observedPDFClipView: NSClipView?
    private var rotationAccumulator: CGFloat = 0
    private var previewBackgroundColor = NSColor.textBackgroundColor
    private var drawsPreviewBackground = true
    private var lastAppliedPDFScrollBackgroundAppearance: PDFScrollBackgroundAppearance?
    private static let documentLoadQueue = DispatchQueue(
        label: "com.cmux.file-preview.pdf-document-load",
        qos: .userInitiated
    )

    private struct PDFScrollBackgroundAppearance {
        let hostIdentifiers: Set<ObjectIdentifier>
        let backgroundColor: NSColor
        let drawsBackground: Bool

        func matches(_ other: PDFScrollBackgroundAppearance) -> Bool {
            hostIdentifiers == other.hostIdentifiers
                && drawsBackground == other.drawsBackground
                && backgroundColor.isEqual(other.backgroundColor)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removePDFScrollObserver()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerFocusEndpoint()
        updatePDFThumbnailSelectionFocus()
    }

    override func layout() {
        super.layout()
        applyBackgroundAppearance()
        if !didSetInitialSidebarWidth, bounds.width > 0 {
            didSetInitialSidebarWidth = true
            let initialWidth = clampedSidebarWidth(lastSidebarWidth)
            lastSidebarWidth = initialWidth
            splitView.setPosition(initialWidth, ofDividerAt: 0)
            splitView.adjustSubviews()
            refreshPDFSmartFitWithoutViewportRestore()
        }
        layoutFloatingChrome()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let chromePoint = convert(point, to: chromeHost)
        if let chromeHit = chromeHost.hitTest(chromePoint) {
            return chromeHit
        }
        return super.hitTest(point)
    }

    func setPanel(_ panel: FilePreviewPanel) {
        self.panel = panel
        registerFocusEndpoint()
    }

    func close() {
        removeFromSuperview()
        removePDFScrollObserver()
        NotificationCenter.default.removeObserver(self)
        pdfView.document = nil
        thumbnailView.setDocument(nil)
        outlineRoot = nil
        currentURL = nil
        panel = nil
    }

    func setBackgroundAppearance(backgroundColor: NSColor, drawsBackground: Bool) {
        guard previewBackgroundColor != backgroundColor || drawsPreviewBackground != drawsBackground else { return }
        previewBackgroundColor = backgroundColor
        drawsPreviewBackground = drawsBackground
        invalidatePDFScrollBackgroundAppearance()
        applyBackgroundAppearance()
    }

    func setURL(_ url: URL) {
        guard currentURL != url else {
            applyPreferredSidebarWidthIfNeeded()
            updatePageControls()
            refreshPDFSmartFitPreservingVisibleTop()
            return
        }
        currentURL = url
        updateChromeRootViews()
        pdfView.document = nil
        thumbnailView.setDocument(nil)
        outlineRoot = nil
        titleLabel.stringValue = url.lastPathComponent
        rotationAccumulator = 0
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        pdfView.autoScales = true
        applyDisplayMode()
        outlineView.reloadData()
        updateSidebarContent()
        applyPreferredSidebarWidthIfNeeded()
        updatePageControls()
        refreshPDFSmartFitWithoutViewportRestore()

        let loadURL = url
        Self.documentLoadQueue.async { [weak self] in
            let document = PDFDocument(url: loadURL)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentURL == loadURL else { return }
                self.applyLoadedPDFDocument(document, for: loadURL)
            }
        }
    }

    private func applyLoadedPDFDocument(_ document: PDFDocument?, for url: URL) {
        pdfView.document = document
        thumbnailView.setDocument(document)
        outlineRoot = document?.outlineRoot
        titleLabel.stringValue = url.lastPathComponent
        pdfView.autoScales = true
        applyDisplayMode()
        updatePDFScrollObserver()
        outlineView.reloadData()
        updateSidebarContent()
        applyPreferredSidebarWidthIfNeeded()
        updatePageControls(scrollThumbnailToVisible: false)
        invalidatePDFScrollBackgroundAppearance()
        applyBackgroundAppearance()
        refreshPDFSmartFitWithoutViewportRestore()
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        setupSplitView()
        setupSidebar()
        setupPDFView()
        setupFloatingChrome()
        applyBackgroundAppearance()

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8.0
        pdfView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomPDF(with: event, factor: factor)
        }
        pdfView.onScrollZoom = { [weak self] event in
            self?.zoomPDF(with: event, factor: FilePreviewZoomInteraction.standard.zoomFactor(forScroll: event))
        }
        pdfView.onScroll = { [weak self] in
            self?.updatePageControls()
        }
        pdfView.onSmartMagnify = { [weak self] in
            self?.togglePDFSmartZoom()
        }
        pdfView.onRotate = { [weak self] event in
            self?.rotatePDF(with: event)
        }
        pdfView.onSwipe = { [weak self] event in
            self?.swipePDF(with: event)
        }
        updatePDFScrollObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfChromeStyleChanged),
            name: .filePreviewPDFChromeStyleDidChange,
            object: nil
        )
        registerFocusEndpoint()
    }

    private func setupSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebarHost)
        splitView.addArrangedSubview(contentHost)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupSidebar() {
        sidebarHost.material = .sidebar
        sidebarHost.blendingMode = .withinWindow
        sidebarHost.state = .active

        thumbnailView.onSelectPage = { [weak self] page in
            self?.setActivePDFRegion(.pdfThumbnails)
            self?.goToPDFPage(page, scrollThumbnailToVisible: false)
        }
        thumbnailView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfThumbnails : nil)
        }
        thumbnailView.onPageNavigation = { [weak self] delta in
            self?.navigatePDFPage(by: delta)
        }
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filePreviewPDFOutline"))
        outlineColumn.title = String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents")
        outlineView.addTableColumn(outlineColumn)
        outlineView.outlineTableColumn = outlineColumn
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfOutline : nil)
        }
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.autohidesScrollers = true
        outlineScrollView.borderType = .noBorder
        outlineScrollView.drawsBackground = false
        outlineScrollView.documentView = outlineView
        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false

        outlinePlaceholder.stringValue = String(
            localized: "filePreview.pdf.noTableOfContents",
            defaultValue: "No table of contents"
        )
        outlinePlaceholder.alignment = .center
        outlinePlaceholder.textColor = .secondaryLabelColor
        outlinePlaceholder.translatesAutoresizingMaskIntoConstraints = false

        sidebarHost.addSubview(thumbnailView)
        sidebarHost.addSubview(outlineScrollView)
        sidebarHost.addSubview(outlinePlaceholder)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            outlineScrollView.topAnchor.constraint(equalTo: sidebarHost.topAnchor),
            outlineScrollView.leadingAnchor.constraint(equalTo: sidebarHost.leadingAnchor),
            outlineScrollView.trailingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            outlineScrollView.bottomAnchor.constraint(equalTo: sidebarHost.bottomAnchor),
            outlinePlaceholder.centerXAnchor.constraint(equalTo: sidebarHost.centerXAnchor),
            outlinePlaceholder.centerYAnchor.constraint(equalTo: sidebarHost.centerYAnchor),
            outlinePlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarHost.leadingAnchor, constant: 16),
            outlinePlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: sidebarHost.trailingAnchor, constant: -16),
        ])
    }

    private func setupPDFView() {
        contentHost.wantsLayer = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.onFocusChanged = { [weak self] isActive in
            self?.setActivePDFRegion(isActive ? .pdfCanvas : nil)
        }
        contentHost.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    private func applyBackgroundAppearance() {
        FilePreviewNativeBackground.applyRootLayer(
            to: self,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        FilePreviewNativeBackground.applyRootLayer(
            to: contentHost,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        let resolvedBackgroundColor = FilePreviewNativeBackground.resolvedColor(
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        pdfView.backgroundColor = resolvedBackgroundColor
        let scrollBackgroundAppearance = currentPDFScrollBackgroundAppearance(
            resolvedBackgroundColor: resolvedBackgroundColor
        )
        guard shouldApplyPDFScrollBackground(scrollBackgroundAppearance) else { return }
        FilePreviewNativeBackground.applyScrollBackgrounds(
            in: pdfView,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        lastAppliedPDFScrollBackgroundAppearance = scrollBackgroundAppearance
    }

    private func invalidatePDFScrollBackgroundAppearance() {
        lastAppliedPDFScrollBackgroundAppearance = nil
    }

    private func currentPDFScrollBackgroundAppearance(
        resolvedBackgroundColor: NSColor
    ) -> PDFScrollBackgroundAppearance {
        var hostIdentifiers = FilePreviewNativeBackground.scrollBackgroundHostIdentifiers(in: pdfView)
        if hostIdentifiers.isEmpty {
            hostIdentifiers.insert(ObjectIdentifier(pdfView))
        }
        return PDFScrollBackgroundAppearance(
            hostIdentifiers: hostIdentifiers,
            backgroundColor: resolvedBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
    }

    private func shouldApplyPDFScrollBackground(_ appearance: PDFScrollBackgroundAppearance) -> Bool {
        guard let lastAppliedPDFScrollBackgroundAppearance else { return true }
        return !lastAppliedPDFScrollBackgroundAppearance.matches(appearance)
    }

    private func setupFloatingChrome() {
        chromeHost.frame = bounds.width > 0 && bounds.height > 0
            ? bounds
            : NSRect(x: 0, y: 0, width: 480, height: 320)
        chromeHost.autoresizingMask = []
        addSubview(chromeHost, positioned: .above, relativeTo: splitView)

        sidebarChromeHost.translatesAutoresizingMaskIntoConstraints = false
        zoomChromeHost.translatesAutoresizingMaskIntoConstraints = false
        updateChromeRootViews()

        chromeHost.addSubview(sidebarChromeHost)
        chromeHost.addSubview(zoomChromeHost)
        chromeHost.interactiveOverlayViews = [sidebarChromeHost, zoomChromeHost]

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, pageLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        chromeHost.addSubview(titleStack)

        let zoomWidthConstraint = zoomChromeHost.widthAnchor.constraint(equalToConstant: Metrics.floatingControlsWidth)
        zoomWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            sidebarChromeHost.topAnchor.constraint(equalTo: chromeHost.topAnchor, constant: 10),
            sidebarChromeHost.leadingAnchor.constraint(equalTo: chromeHost.leadingAnchor, constant: 10),
            sidebarChromeHost.widthAnchor.constraint(equalToConstant: 68),
            sidebarChromeHost.heightAnchor.constraint(equalToConstant: Metrics.floatingChromeHeight),

            zoomChromeHost.topAnchor.constraint(equalTo: chromeHost.topAnchor, constant: 10),
            zoomChromeHost.trailingAnchor.constraint(equalTo: chromeHost.trailingAnchor, constant: -10),
            zoomWidthConstraint,
            zoomChromeHost.heightAnchor.constraint(equalToConstant: Metrics.floatingChromeHeight),

            titleStack.leadingAnchor.constraint(equalTo: sidebarChromeHost.trailingAnchor, constant: 12),
            titleStack.centerYAnchor.constraint(equalTo: sidebarChromeHost.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: zoomChromeHost.leadingAnchor, constant: -12),
        ])
    }

    private func layoutFloatingChrome() {
        let contentFrame = contentHost.convert(contentHost.bounds, to: self)
        guard contentFrame.width > 0, contentFrame.height > 0 else { return }
        if chromeHost.frame != contentFrame {
            chromeHost.frame = contentFrame
        }
        chromeHost.needsLayout = true
    }

    private func updateChromeRootViews() {
        sidebarChromeHost.rootView = AnyView(FilePreviewPDFSidebarChromeView(
            isSidebarVisible: isSidebarVisible,
            sidebarMode: sidebarMode,
            displayMode: displayMode,
            chromeStyleVariant: chromeStyleVariant,
            strings: FilePreviewPDFSidebarChromeStrings(
                sidebarOptions: String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"),
                hideSidebar: String(localized: "filePreview.pdf.hideSidebar", defaultValue: "Hide Sidebar"),
                showSidebar: String(localized: "filePreview.pdf.showSidebar", defaultValue: "Show Sidebar"),
                thumbnails: String(localized: "filePreview.pdf.thumbnails", defaultValue: "Thumbnails"),
                tableOfContents: String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents"),
                continuousScroll: String(localized: "filePreview.pdf.continuousScroll", defaultValue: "Continuous Scroll"),
                singlePage: String(localized: "filePreview.pdf.singlePage", defaultValue: "Single Page"),
                twoPages: String(localized: "filePreview.pdf.twoPages", defaultValue: "Two Pages")
            ),
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            selectThumbnails: { [weak self] in self?.selectThumbnailSidebar() },
            selectTableOfContents: { [weak self] in self?.selectTableOfContentsSidebar() },
            selectContinuousScroll: { [weak self] in self?.selectContinuousScroll() },
            selectSinglePage: { [weak self] in self?.selectSinglePage() },
            selectTwoPages: { [weak self] in self?.selectTwoPages() }
        ))
        zoomChromeHost.rootView = AnyView(FilePreviewPDFZoomChromeView(
            chromeStyleVariant: chromeStyleVariant,
            strings: FilePreviewPDFZoomChromeStrings(
                zoomControls: String(localized: "filePreview.pdf.zoomControls", defaultValue: "Zoom Controls"),
                zoomOut: String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out"),
                actualSize: String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size"),
                zoomIn: String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In"),
                zoomToFit: String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit"),
                rotateLeft: String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left"),
                rotateRight: String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right")
            ),
            fileOpenMenu: currentURL.map { AnyView(FileExternalOpenMenu(fileURL: $0, style: .chrome)) },
            zoomOut: { [weak self] in self?.zoomOut() },
            actualSize: { [weak self] in self?.actualSize() },
            zoomIn: { [weak self] in self?.zoomIn() },
            zoomToFit: { [weak self] in self?.zoomToFit() },
            rotateLeft: { [weak self] in self?.rotateLeft() },
            rotateRight: { [weak self] in self?.rotateRight() }
        ))
    }

    @objc private func zoomOut() {
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor / FilePreviewZoomInteraction.standard.step, preservingVisibleCenter: true)
    }

    @objc private func zoomIn() {
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor * FilePreviewZoomInteraction.standard.step, preservingVisibleCenter: true)
    }

    @objc private func zoomToFit() {
        pdfView.autoScales = true
        refreshPDFSmartFitPreservingVisibleCenter()
    }

    @objc private func actualSize() {
        pdfView.autoScales = false
        setPDFScaleFactor(1.0, preservingVisibleCenter: true)
    }

    @objc private func rotateLeft() {
        rotateCurrentPDFPage(by: -90)
    }

    @objc private func rotateRight() {
        rotateCurrentPDFPage(by: 90)
    }

    @objc private func toggleSidebar() {
        isSidebarVisible.toggle()
        updateSidebarVisibility()
        updateChromeRootViews()
    }

    @objc private func selectThumbnailSidebar() {
        sidebarMode = .thumbnails
        isSidebarVisible = true
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        logSidebarWidth(reason: "selectThumbnails", proposed: lastSidebarWidth)
        updateSidebarVisibility()
        updateSidebarContent()
        updateChromeRootViews()
    }

    @objc private func selectTableOfContentsSidebar() {
        sidebarMode = .tableOfContents
        isSidebarVisible = true
        didUserResizeSidebar = false
        lastSidebarWidth = preferredSidebarWidthForCurrentMode()
        logSidebarWidth(reason: "selectTableOfContents", proposed: lastSidebarWidth)
        updateSidebarVisibility()
        updateSidebarContent()
        updateChromeRootViews()
    }

    @objc private func selectContinuousScroll() {
        displayMode = .continuousScroll
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func selectSinglePage() {
        displayMode = .singlePage
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func selectTwoPages() {
        displayMode = .twoPages
        applyDisplayMode()
        updateChromeRootViews()
    }

    @objc private func pdfPageChanged() {
        logPDFResizeProbe(
            "pageChanged suppressed=\(suppressPDFPageChangeNotifications ? 1 : 0) \(pdfDebugState())"
        )
        guard !suppressPDFPageChangeNotifications else { return }
        updatePageControls()
    }

    @objc private func pdfChromeStyleChanged() {
        let variant = FilePreviewPDFChromeStyleVariant.current()
        guard variant != chromeStyleVariant else { return }
        chromeStyleVariant = variant
        updateChromeRootViews()
    }

    @objc private func pdfClipBoundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView === observedPDFClipView,
              pdfView.document != nil,
              !suppressPDFPageChangeNotifications else { return }
        updatePageControls()
    }

    private func updatePageControls(
        pageIndexOverride: Int? = nil,
        scrollThumbnailToVisible: Bool = true
    ) {
        guard let document = pdfView.document, document.pageCount > 0 else {
            pageLabel.stringValue = ""
            logPDFResizeProbe("updatePageControls emptyDoc scrollThumb=\(scrollThumbnailToVisible ? 1 : 0)")
            return
        }

        let pageIndex: Int
        if let pageIndexOverride,
           pageIndexOverride >= 0,
           pageIndexOverride < document.pageCount {
            pageIndex = pageIndexOverride
        } else if let visiblePageIndex = visiblePDFPageIndex(for: document) {
            pageIndex = visiblePageIndex
        } else {
            pageIndex = 0
        }
        let format = String(localized: "filePreview.pdf.pageCount", defaultValue: "Page %d of %d")
        pageLabel.stringValue = String.localizedStringWithFormat(format, pageIndex + 1, document.pageCount)
        thumbnailView.selectPage(at: pageIndex, scrollToVisible: scrollThumbnailToVisible)
        let explicit = pageIndexOverride == nil ? 0 : 1
        logPDFResizeProbe(
            "updatePageControls page=\(pageIndex + 1)/\(document.pageCount) " +
            "explicit=\(explicit) scrollThumb=\(scrollThumbnailToVisible ? 1 : 0) \(pdfDebugState())"
        )
    }

    private func visiblePDFPageIndex(for document: PDFDocument) -> Int? {
        let page = displayMode == .continuousScroll
            ? selectedVisiblePDFPage()
            : pdfView.currentPage
        guard let page else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        return pageIndex
    }

    private func selectedVisiblePDFPage() -> PDFPage? {
        FilePreviewPDFVisiblePageResolver.selectedVisiblePage(in: pdfView, scrollView: pdfScrollView())
    }

    private func topVisiblePDFPage() -> PDFPage? {
        FilePreviewPDFVisiblePageResolver.topVisiblePage(in: pdfView, scrollView: pdfScrollView())
    }

    private func updateSidebarVisibility() {
        if isSidebarVisible {
            sidebarHost.isHidden = false
            let targetWidth = didUserResizeSidebar
                ? lastSidebarWidth
                : preferredSidebarWidthForCurrentMode()
            applySidebarWidth(targetWidth)
        } else {
            let currentSidebarWidth = sidebarHost.frame.width
            if currentSidebarWidth >= minimumSidebarWidthForCurrentMode() {
                lastSidebarWidth = currentSidebarWidth
            }
            applyPDFViewportChange {
                self.sidebarHost.isHidden = true
                self.splitView.adjustSubviews()
                self.splitView.layoutSubtreeIfNeeded()
                self.layoutFloatingChrome()
            }
        }
        layoutFloatingChrome()
    }

    private func clampedSidebarWidth(_ proposedWidth: CGFloat) -> CGFloat {
        FilePreviewPDFSizing.clampedSidebarWidth(
            proposedWidth,
            containerWidth: max(splitView.bounds.width, bounds.width),
            dividerThickness: splitView.dividerThickness,
            minimumWidth: minimumSidebarWidthForCurrentMode()
        )
    }

    private func minimumSidebarWidthForCurrentMode() -> CGFloat {
        switch sidebarMode {
        case .thumbnails:
            FilePreviewPDFSizing.minimumThumbnailSidebarWidth
        case .tableOfContents:
            Metrics.minimumSidebarWidth
        }
    }

    private func preferredSidebarWidthForCurrentMode() -> CGFloat {
        switch sidebarMode {
        case .thumbnails:
            thumbnailView.preferredSidebarWidth()
        case .tableOfContents:
            FilePreviewPDFSizing.preferredOutlineSidebarWidth(for: outlineRoot)
        }
    }

    private func logSidebarWidth(
        reason: String,
        proposed: CGFloat? = nil,
        applied: CGFloat? = nil
    ) {
        #if DEBUG
        let mode = sidebarMode == .tableOfContents ? "toc" : "thumbnails"
        let currentWidth = sidebarHost.frame.width
        let preferredWidth = preferredSidebarWidthForCurrentMode()
        let thumbnailWidth = thumbnailView.preferredSidebarWidth()
        let tocWidth = FilePreviewPDFSizing.preferredOutlineSidebarWidth(for: outlineRoot)
        cmuxDebugLog(
            "filePreview.pdf.sidebarWidth reason=\(reason) mode=\(mode) " +
            "current=\(formatSidebarWidth(currentWidth)) " +
            "proposed=\(formatSidebarWidth(proposed)) " +
            "applied=\(formatSidebarWidth(applied)) " +
            "preferred=\(formatSidebarWidth(preferredWidth)) " +
            "thumbnailPreferred=\(formatSidebarWidth(thumbnailWidth)) " +
            "tocPreferred=\(formatSidebarWidth(tocWidth)) " +
            "min=\(formatSidebarWidth(minimumSidebarWidthForCurrentMode())) " +
            "content=\(formatSidebarWidth(contentHost.frame.width))"
        )
        #endif
    }

    #if DEBUG
    private func formatSidebarWidth(_ width: CGFloat?) -> String {
        guard let width, width.isFinite else { return "nil" }
        return String(format: "%.1f", Double(width))
    }
    #endif

    private func applyPreferredSidebarWidthIfNeeded() {
        guard !didUserResizeSidebar,
              didSetInitialSidebarWidth,
              isSidebarVisible,
              !sidebarHost.isHidden else { return }
        let preferredWidth = preferredSidebarWidthForCurrentMode()
        guard abs(sidebarHost.frame.width - preferredWidth) > 0.5 else { return }
        logSidebarWidth(reason: "applyPreferred", proposed: preferredWidth)
        applySidebarWidth(preferredWidth)
    }

    private func applySidebarWidth(_ proposedWidth: CGFloat) {
        let width = clampedSidebarWidth(proposedWidth)
        lastSidebarWidth = width
        logSidebarWidth(reason: "applySidebarWidth", proposed: proposedWidth, applied: width)
        let applyWidth = {
            self.isApplyingSidebarWidth = true
            defer { self.isApplyingSidebarWidth = false }
            self.splitView.setPosition(width, ofDividerAt: 0)
            self.splitView.adjustSubviews()
            self.splitView.layoutSubtreeIfNeeded()
            self.layoutFloatingChrome()
        }

        applyPDFViewportChange(applyWidth)
    }

    private func applyPDFViewportChange(_ change: () -> Void) {
        guard pdfView.document != nil else {
            change()
            return
        }
        preserveVisiblePDFTop {
            change()
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    func splitViewWillResizeSubviews(_ notification: Notification) {
        guard !isApplyingSidebarWidth,
              isSidebarVisible,
              !sidebarHost.isHidden,
              pdfView.document != nil else { return }
        pdfResizeSequence += 1
        activePDFResizeID = pdfResizeSequence
        preparePDFViewportSnapshot()
        pendingSidebarResizeSnapshot = FilePreviewPDFViewportSnapshot.capture(
            in: pdfView,
            scrollView: pdfScrollView(),
            anchor: .top
        )
        logPDFResizeProbe(
            "will id=\(activePDFResizeID ?? -1) event=\(debugEventType()) " +
            "snapshot=\(debugSnapshot(pendingSidebarResizeSnapshot)) \(pdfDebugState())"
        )
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isSidebarVisible, !sidebarHost.isHidden else { return }
        let sidebarWidth = sidebarHost.frame.width
        guard sidebarWidth >= minimumSidebarWidthForCurrentMode() else { return }
        logSidebarWidth(reason: "splitViewDidResize", applied: sidebarWidth)
        guard !isApplyingSidebarWidth else { return }
        let resizeID: Int
        if let activePDFResizeID {
            resizeID = activePDFResizeID
        } else {
            pdfResizeSequence += 1
            resizeID = pdfResizeSequence
            self.activePDFResizeID = resizeID
        }
        logPDFResizeProbe(
            "did.begin id=\(resizeID) event=\(debugEventType()) " +
            "snapshot=\(debugSnapshot(pendingSidebarResizeSnapshot)) \(pdfDebugState())"
        )
        if NSApp.currentEvent?.type == .leftMouseDragged {
            didUserResizeSidebar = true
        }
        lastSidebarWidth = sidebarWidth
        layoutFloatingChrome()
        let resizeSnapshot = pendingSidebarResizeSnapshot
        pendingSidebarResizeSnapshot = nil
        withSuppressedPDFPageChangeNotifications {
            if let resizeSnapshot {
                refreshPDFSmartFitWithoutViewportRestore()
                resizeSnapshot.restore(in: pdfView, scrollView: pdfScrollView())
            } else {
                refreshPDFSmartFitPreservingVisibleTop()
            }
        }
        logPDFResizeProbe("did.end id=\(resizeID) \(pdfDebugState())")
        activePDFResizeID = nil
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        minimumSidebarWidthForCurrentMode()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        clampedSidebarWidth(Metrics.maximumSidebarWidth)
    }

    private func updateSidebarContent() {
        let showingThumbnails = sidebarMode == .thumbnails
        let showingTableOfContents = sidebarMode == .tableOfContents
        let hasOutline = (outlineRoot?.numberOfChildren ?? 0) > 0
        thumbnailView.isHidden = !showingThumbnails
        outlineScrollView.isHidden = !showingTableOfContents || !hasOutline
        outlinePlaceholder.isHidden = !showingTableOfContents || hasOutline
    }

    private func applyDisplayMode() {
        switch displayMode {
        case .continuousScroll:
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        case .singlePage:
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .vertical
        case .twoPages:
            pdfView.displayMode = .twoUp
            pdfView.displayDirection = .horizontal
        }
        pdfView.autoScales = true
        updatePDFScrollObserver()
        refreshPDFSmartFitPreservingVisibleTop()
    }

    private func refreshPDFSmartFitWithoutViewportRestore() {
        guard pdfView.document != nil, pdfView.autoScales else { return }
        logPDFResizeProbe("smartFit.begin \(pdfDebugState())")
        contentHost.layoutSubtreeIfNeeded()
        pdfView.layoutSubtreeIfNeeded()
        pdfView.autoScales = false
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        updatePDFScrollObserver()
        logPDFResizeProbe("smartFit.end \(pdfDebugState())")
    }

    private func refreshPDFSmartFitPreservingVisibleTop() {
        preserveVisiblePDFTop {
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    private func refreshPDFSmartFitPreservingVisibleCenter() {
        preserveVisiblePDFCenter {
            refreshPDFSmartFitWithoutViewportRestore()
        }
    }

    private func zoomPDF(with event: NSEvent, factor: CGFloat) {
        guard pdfView.document != nil else { return }
        guard factor.isFinite, factor > 0 else { return }
        pdfView.autoScales = false
        setPDFScaleFactor(pdfView.scaleFactor * factor, preservingVisibleCenter: true)
    }

    private func togglePDFSmartZoom() {
        if pdfView.autoScales {
            actualSize()
        } else {
            zoomToFit()
        }
    }

    private func rotatePDF(with event: NSEvent) {
        rotationAccumulator += CGFloat(event.rotation)
        if rotationAccumulator >= 45 {
            rotateCurrentPDFPage(by: -90)
            rotationAccumulator = 0
        } else if rotationAccumulator <= -45 {
            rotateCurrentPDFPage(by: 90)
            rotationAccumulator = 0
        }
    }

    private func swipePDF(with event: NSEvent) {
        if event.deltaX < 0 {
            navigatePDFPage(by: 1)
        } else if event.deltaX > 0 {
            navigatePDFPage(by: -1)
        }
    }

    private func navigatePDFPage(by delta: Int) {
        guard delta != 0,
              let document = pdfView.document,
              document.pageCount > 0 else { return }
        let currentPageIndex = visiblePDFPageIndex(for: document) ?? 0
        let nextPageIndex = min(max(currentPageIndex + delta, 0), document.pageCount - 1)
        guard nextPageIndex != currentPageIndex,
              let page = document.page(at: nextPageIndex) else { return }
        goToPDFPage(page)
    }

    private func goToPDFPage(_ page: PDFPage, scrollThumbnailToVisible: Bool = true) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return }
        withSuppressedPDFPageChangeNotifications {
            pdfView.go(to: page)
        }
        updatePageControls(
            pageIndexOverride: pageIndex,
            scrollThumbnailToVisible: scrollThumbnailToVisible
        )
    }

    private func rotateCurrentPDFPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        page.rotation = normalizedRotation(page.rotation + degrees)
        pdfView.layoutDocumentView()
        pdfView.setNeedsDisplay(pdfView.bounds)
        if let document = pdfView.document {
            thumbnailView.reloadPage(at: document.index(for: page))
        }
    }

    private func setPDFScaleFactor(_ nextScale: CGFloat, preservingVisibleCenter: Bool = false) {
        let clamped = min(max(nextScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        guard clamped.isFinite else { return }
        if preservingVisibleCenter {
            preserveVisiblePDFCenter {
                pdfView.scaleFactor = clamped
            }
        } else {
            pdfView.scaleFactor = clamped
        }
    }

    private func preparePDFViewportSnapshot() {
        contentHost.layoutSubtreeIfNeeded()
        pdfView.layoutSubtreeIfNeeded()
    }

    private func preserveVisiblePDFTop(_ viewportChange: () -> Void) {
        preservePDFViewport(anchor: .top, viewportChange)
    }

    private func preserveVisiblePDFCenter(_ viewportChange: () -> Void) {
        preservePDFViewport(anchor: .center, viewportChange)
    }

    private func preservePDFViewport(
        anchor: FilePreviewPDFViewportAnchor,
        _ viewportChange: () -> Void
    ) {
        preparePDFViewportSnapshot()
        guard let snapshot = FilePreviewPDFViewportSnapshot.capture(
            in: pdfView,
            scrollView: pdfScrollView(),
            anchor: anchor
        ) else {
            logPDFResizeProbe("preserve.noSnapshot anchor=\(debugAnchor(anchor)) \(pdfDebugState())")
            viewportChange()
            return
        }
        logPDFResizeProbe(
            "preserve.begin anchor=\(debugAnchor(anchor)) snapshot=\(debugSnapshot(snapshot)) \(pdfDebugState())"
        )
        withSuppressedPDFPageChangeNotifications {
            viewportChange()
            snapshot.restore(in: pdfView, scrollView: pdfScrollView())
        }
        logPDFResizeProbe("preserve.end anchor=\(debugAnchor(anchor)) \(pdfDebugState())")
    }

    private func withSuppressedPDFPageChangeNotifications(_ body: () -> Void) {
        let previousValue = suppressPDFPageChangeNotifications
        suppressPDFPageChangeNotifications = true
        defer { suppressPDFPageChangeNotifications = previousValue }
        body()
    }

    private func registerFocusEndpoint() {
        panel?.attachPreviewFocus(root: pdfView, primaryResponder: pdfView, intent: .pdfCanvas)
        panel?.attachPreviewFocus(
            root: thumbnailView,
            primaryResponder: thumbnailView.focusResponder(),
            intent: .pdfThumbnails
        )
        panel?.attachPreviewFocus(root: outlineView, primaryResponder: outlineView, intent: .pdfOutline)
    }

    private func setActivePDFRegion(_ region: FilePreviewPanelFocusIntent?) {
        guard activePDFRegion != region else { return }
        activePDFRegion = region
        thumbnailView.setSelectionActive(region == .pdfThumbnails)
        guard let region else { return }
        panel?.noteFilePreviewFocusIntent(region)
        AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: window)
    }

    private func updatePDFThumbnailSelectionFocus() {
        setActivePDFRegion(currentPDFFocusRegion())
    }

    private func updatePDFScrollObserver() {
        guard let clipView = pdfScrollView()?.contentView else { return }
        guard observedPDFClipView !== clipView else { return }
        removePDFScrollObserver()
        observedPDFClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfClipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func removePDFScrollObserver() {
        if let observedPDFClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedPDFClipView
            )
        }
        observedPDFClipView = nil
    }

    private func currentPDFFocusRegion() -> FilePreviewPanelFocusIntent? {
        guard window?.isKeyWindow == true,
              !isHiddenOrHasHiddenAncestor,
              let intent = panel?.currentFilePreviewFocusIntent(in: window) else { return nil }
        switch intent {
        case .pdfCanvas, .pdfThumbnails, .pdfOutline:
            return intent
        case .textEditor, .imageCanvas, .mediaPlayer, .quickLook:
            return nil
        }
    }

    #if DEBUG
    private func logPDFResizeProbe(_ message: @autoclosure () -> String) {
        cmuxDebugLog("filePreview.pdf.resize \(message())")
    }

    private func pdfDebugState() -> String {
        let document = pdfView.document
        let pageDescription: String
        if let document, let currentPage = pdfView.currentPage {
            let pageIndex = document.index(for: currentPage)
            pageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown/\(document.pageCount)"
        } else if let document {
            pageDescription = "nil/\(document.pageCount)"
        } else {
            pageDescription = "nil"
        }
        let topPageDescription: String
        if let document, let topPage = topVisiblePDFPage() {
            let pageIndex = document.index(for: topPage)
            topPageDescription = pageIndex >= 0 ? "\(pageIndex + 1)/\(document.pageCount)" : "unknown/\(document.pageCount)"
        } else {
            topPageDescription = "nil"
        }
        let scrollView = pdfScrollView()
        let clipBounds = scrollView?.contentView.bounds
        let documentBounds = scrollView?.documentView?.bounds
        return "mode=\(sidebarMode == .tableOfContents ? "toc" : "thumbs") " +
            "visible=\(isSidebarVisible ? 1 : 0) " +
            "sidebar=\(debugNumber(sidebarHost.frame.width)) " +
            "content=\(debugNumber(contentHost.frame.width)) " +
            "auto=\(pdfView.autoScales ? 1 : 0) " +
            "scale=\(debugNumber(pdfView.scaleFactor)) " +
            "page=\(pageDescription) " +
            "topPage=\(topPageDescription) " +
            "clip=\(debugRect(clipBounds)) " +
            "doc=\(debugRect(documentBounds))"
    }

    private func debugSnapshot(_ snapshot: FilePreviewPDFViewportSnapshot?) -> String {
        snapshot?.debugSummary(document: pdfView.document) ?? "nil"
    }

    private func debugAnchor(_ anchor: FilePreviewPDFViewportAnchor) -> String {
        switch anchor {
        case .center:
            "center"
        case .top:
            "top"
        }
    }

    private func debugEventType() -> String {
        guard let event = NSApp.currentEvent else { return "nil" }
        return "\(event.type.rawValue)"
    }

    private func debugRect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(\(debugNumber(rect.origin.x)),\(debugNumber(rect.origin.y)) " +
            "\(debugNumber(rect.width))x\(debugNumber(rect.height)))"
    }

    private func debugNumber(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.1f", Double(value))
    }
    #else
    private func logPDFResizeProbe(_ message: @autoclosure () -> String) {}

    private func pdfDebugState() -> String { "" }

    private func debugSnapshot(_ snapshot: FilePreviewPDFViewportSnapshot?) -> String { "" }

    private func debugAnchor(_ anchor: FilePreviewPDFViewportAnchor) -> String { "" }

    private func debugEventType() -> String { "" }
    #endif

    private func pdfScrollView() -> NSScrollView? {
        firstScrollView(in: pdfView)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let outline = item as? PDFOutline ?? outlineRoot
        return outline?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let outline = item as? PDFOutline else { return false }
        return outline.numberOfChildren > 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let outline = item as? PDFOutline ?? outlineRoot
        return outline?.child(at: index) ?? NSNull()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let outline = item as? PDFOutline else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("filePreviewPDFOutlineCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeOutlineCell(identifier: identifier)
        cell.textField?.stringValue = outline.label ?? ""
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        setActivePDFRegion(.pdfOutline)
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let outline = outlineView.item(atRow: selectedRow) as? PDFOutline,
              let destination = outline.destination,
              let page = destination.page else { return }
        goToPDFPage(page)
    }

    private func makeOutlineCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

private struct FilePreviewImageView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewImageContainerView {
        panel.nativeViewSessions.image.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: FilePreviewImageContainerView, context: Context) {
        panel.nativeViewSessions.image.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

final class FilePreviewImageContainerView: NSView {
    private let scrollView = FilePreviewImageScrollView()
    private let documentView = FilePreviewImageDocumentView()
    private let chromeHost = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))
    private weak var panel: FilePreviewPanel?
    private var currentURL: URL?
    private var imageSize = CGSize(width: 1, height: 1)
    private var scale: CGFloat = 1
    private var isFitMode = true
    private var rotationDegrees = 0
    private var rotationAccumulator: CGFloat = 0
    private var previewBackgroundColor = NSColor.textBackgroundColor
    private var drawsPreviewBackground = true
    private static let imageLoadQueue = DispatchQueue(
        label: "com.cmux.file-preview.image-load",
        qos: .userInitiated
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerFocusEndpoint()
    }

    override func layout() {
        super.layout()
        applyBackgroundAppearance()
        if isFitMode {
            scale = fitScale()
        }
        applyScale()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            panel?.noteFilePreviewFocusIntent(.imageCanvas)
        }
        return accepted
    }

    func setPanel(_ panel: FilePreviewPanel) {
        self.panel = panel
        registerFocusEndpoint()
    }

    func close() {
        removeFromSuperview()
        documentView.imageView.image = nil
        currentURL = nil
        panel = nil
    }

    func setBackgroundAppearance(backgroundColor: NSColor, drawsBackground: Bool) {
        guard previewBackgroundColor != backgroundColor || drawsPreviewBackground != drawsBackground else { return }
        previewBackgroundColor = backgroundColor
        drawsPreviewBackground = drawsBackground
        applyBackgroundAppearance()
    }

    func setURL(_ url: URL) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        guard currentURL != url else { return }
        currentURL = url
        documentView.imageView.image = nil
        imageSize = normalizedSize(.zero)
        isFitMode = true
        rotationDegrees = 0
        rotationAccumulator = 0
        scale = fitScale()
        applyScale()

        let loadURL = url
        Self.imageLoadQueue.async { [weak self] in
            let image = NSImage(contentsOf: loadURL)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentURL == loadURL else { return }
                self.applyLoadedImage(image)
            }
        }
    }

    private func applyLoadedImage(_ image: NSImage?) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        documentView.imageView.image = image
        imageSize = normalizedSize(image?.size ?? .zero)
        isFitMode = true
        rotationDegrees = 0
        rotationAccumulator = 0
        scale = fitScale()
        applyScale()
    }

    private func registerFocusEndpoint() {
        panel?.attachPreviewFocus(root: self, primaryResponder: self, intent: .imageCanvas)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false

        chromeHost.rootView = AnyView(FilePreviewImageChromeView(
            strings: FilePreviewImageChromeStrings(
                zoomOut: String(localized: "filePreview.image.zoomOut", defaultValue: "Zoom Out"),
                actualSize: String(localized: "filePreview.image.actualSize", defaultValue: "Actual Size"),
                zoomIn: String(localized: "filePreview.image.zoomIn", defaultValue: "Zoom In"),
                zoomToFit: String(localized: "filePreview.image.zoomToFit", defaultValue: "Zoom to Fit"),
                rotateLeft: String(localized: "filePreview.image.rotateLeft", defaultValue: "Rotate Left"),
                rotateRight: String(localized: "filePreview.image.rotateRight", defaultValue: "Rotate Right")
            ),
            zoomOut: { [weak self] in self?.zoomOut() },
            zoomIn: { [weak self] in self?.zoomIn() },
            zoomToFit: { [weak self] in self?.zoomToFit() },
            actualSize: { [weak self] in self?.actualSize() },
            rotateLeft: { [weak self] in self?.rotateLeft() },
            rotateRight: { [weak self] in self?.rotateRight() }
        ))
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        chromeHost.setContentHuggingPriority(.required, for: .horizontal)
        chromeHost.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        scrollView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomImage(with: event, factor: factor)
        }
        scrollView.onScrollZoom = { [weak self] event in
            self?.zoomImage(with: event, factor: FilePreviewZoomInteraction.standard.zoomFactor(forScroll: event))
        }
        scrollView.onSmartMagnify = { [weak self] event in
            self?.toggleImageSmartZoom(with: event)
        }
        scrollView.onRotate = { [weak self] event in
            self?.rotateImage(with: event)
        }
        documentView.onMagnify = { [weak self] event in
            let factor = 1.0 + event.magnification
            self?.zoomImage(with: event, factor: factor)
        }
        documentView.onSmartMagnify = { [weak self] event in
            self?.toggleImageSmartZoom(with: event)
        }
        documentView.onRotate = { [weak self] event in
            self?.rotateImage(with: event)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(chromeHost)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            chromeHost.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            chromeHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chromeHost.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            chromeHost.heightAnchor.constraint(equalToConstant: 40),
        ])
        applyBackgroundAppearance()
    }

    private func applyBackgroundAppearance() {
        let resolvedBackgroundColor = FilePreviewNativeBackground.resolvedColor(
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        FilePreviewNativeBackground.applyRootLayer(
            to: self,
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        scrollView.drawsBackground = drawsPreviewBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsPreviewBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
    }

    @objc private func zoomOut() {
        isFitMode = false
        setImageScale(scale / FilePreviewZoomInteraction.standard.step, preservingVisibleCenter: true)
    }

    @objc private func zoomIn() {
        isFitMode = false
        setImageScale(scale * FilePreviewZoomInteraction.standard.step, preservingVisibleCenter: true)
    }

    @objc private func zoomToFit() {
        isFitMode = true
        scale = fitScale()
        applyScale()
    }

    @objc private func actualSize() {
        isFitMode = false
        setImageScale(1.0, preservingVisibleCenter: true)
    }

    @objc private func rotateLeft() {
        rotateImage(by: -90)
    }

    @objc private func rotateRight() {
        rotateImage(by: 90)
    }

    private func fitScale() -> CGFloat {
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 1, clipSize.height > 1 else { return scale }
        let imageSize = displayedImageSize()
        let widthScale = clipSize.width / max(imageSize.width, 1)
        let heightScale = clipSize.height / max(imageSize.height, 1)
        return clampedImageScale(min(widthScale, heightScale))
    }

    private func applyScale() {
        let imageSize = displayedImageSize()
        let scaledSize = CGSize(
            width: max(1, imageSize.width * scale),
            height: max(1, imageSize.height * scale)
        )
        let clipSize = scrollView.contentView.bounds.size
        documentView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(clipSize.width, scaledSize.width),
                height: max(clipSize.height, scaledSize.height)
            )
        )
        documentView.scaledImageSize = scaledSize
        documentView.rotationDegrees = rotationDegrees
        documentView.needsLayout = true
    }

    private func setImageScale(_ nextScale: CGFloat, preservingVisibleCenter: Bool = false) {
        let clamped = clampedImageScale(nextScale)
        guard clamped.isFinite else { return }
        if preservingVisibleCenter {
            preserveVisibleImageCenter {
                scale = clamped
                applyScale()
            }
        } else {
            scale = clamped
            applyScale()
        }
    }

    private func preserveVisibleImageCenter(_ scaleChange: () -> Void) {
        documentView.layoutSubtreeIfNeeded()
        let clipBounds = scrollView.contentView.bounds
        guard clipBounds.width > 1, clipBounds.height > 1 else {
            scaleChange()
            return
        }

        let anchorInClip = CGPoint(x: clipBounds.midX, y: clipBounds.midY)
        let oldImageFrame = documentView.imageView.frame
        let anchorInDocument = documentView.convert(anchorInClip, from: scrollView.contentView)
        let anchorRatio = CGPoint(
            x: FilePreviewViewport.normalizedAnchorRatio(
                anchorInDocument.x - oldImageFrame.minX,
                length: oldImageFrame.width
            ),
            y: FilePreviewViewport.normalizedAnchorRatio(
                anchorInDocument.y - oldImageFrame.minY,
                length: oldImageFrame.height
            )
        )

        scaleChange()
        documentView.layoutSubtreeIfNeeded()

        let newImageFrame = documentView.imageView.frame
        let targetDocumentPoint = CGPoint(
            x: newImageFrame.minX + (newImageFrame.width * anchorRatio.x),
            y: newImageFrame.minY + (newImageFrame.height * anchorRatio.y)
        )
        scrollDocumentPoint(targetDocumentPoint, toClipPoint: anchorInClip)
    }

    private func zoomImage(with event: NSEvent, factor: CGFloat) {
        guard documentView.imageView.image != nil else { return }
        guard factor.isFinite, factor > 0 else { return }

        let anchorInClip = scrollView.contentView.convert(event.locationInWindow, from: nil)
        let oldImageFrame = documentView.imageView.frame
        let anchorInDocument = documentView.convert(event.locationInWindow, from: nil)
        let anchorRatio = CGPoint(
            x: normalizedAnchorRatio(
                anchorInDocument.x - oldImageFrame.minX,
                length: oldImageFrame.width
            ),
            y: normalizedAnchorRatio(
                anchorInDocument.y - oldImageFrame.minY,
                length: oldImageFrame.height
            )
        )

        isFitMode = false
        scale = clampedImageScale(scale * factor)
        applyScale()
        documentView.layoutSubtreeIfNeeded()

        let newImageFrame = documentView.imageView.frame
        let anchoredDocumentPoint = CGPoint(
            x: newImageFrame.minX + (newImageFrame.width * anchorRatio.x),
            y: newImageFrame.minY + (newImageFrame.height * anchorRatio.y)
        )
        scrollDocumentPoint(anchoredDocumentPoint, toClipPoint: anchorInClip)
    }

    private func toggleImageSmartZoom(with event: NSEvent) {
        guard documentView.imageView.image != nil else { return }
        if isFitMode {
            isFitMode = false
            scale = 1.0
            applyScale()
            documentView.layoutSubtreeIfNeeded()
            let anchorInClip = scrollView.contentView.convert(event.locationInWindow, from: nil)
            let anchorInDocument = documentView.convert(event.locationInWindow, from: nil)
            scrollDocumentPoint(anchorInDocument, toClipPoint: anchorInClip)
        } else {
            zoomToFit()
        }
    }

    private func rotateImage(with event: NSEvent) {
        rotationAccumulator += CGFloat(event.rotation)
        if rotationAccumulator >= 45 {
            rotateImage(by: -90)
            rotationAccumulator = 0
        } else if rotationAccumulator <= -45 {
            rotateImage(by: 90)
            rotationAccumulator = 0
        }
    }

    private func rotateImage(by degrees: Int) {
        rotationDegrees = normalizedRotation(rotationDegrees + degrees)
        if isFitMode {
            scale = fitScale()
        }
        applyScale()
    }

    private func scrollDocumentPoint(_ documentPoint: CGPoint, toClipPoint clipPoint: CGPoint) {
        let clipSize = scrollView.contentView.bounds.size
        let clipOrigin = scrollView.contentView.bounds.origin
        let anchorOffsetInClip = CGPoint(
            x: clipPoint.x - clipOrigin.x,
            y: clipPoint.y - clipOrigin.y
        )
        let documentSize = documentView.bounds.size
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let nextOrigin = CGPoint(
            x: min(max(0, documentPoint.x - anchorOffsetInClip.x), maxOrigin.x),
            y: min(max(0, documentPoint.y - anchorOffsetInClip.y), maxOrigin.y)
        )
        scrollView.contentView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func normalizedAnchorRatio(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 1 else { return 0.5 }
        return min(max(value / length, 0), 1)
    }

    private func clampedImageScale(_ nextScale: CGFloat) -> CGFloat {
        min(max(nextScale, 0.05), 16.0)
    }

    private func displayedImageSize() -> CGSize {
        if abs(rotationDegrees) % 180 == 90 {
            return CGSize(width: imageSize.height, height: imageSize.width)
        }
        return imageSize
    }

    private func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    private func normalizedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width), height: max(1, size.height))
    }
}

private struct FilePreviewMediaView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        panel.nativeViewSessions.media.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        panel.nativeViewSessions.media.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

private struct QuickLookPreviewView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    final class Coordinator {
        var quickLook: FilePreviewQuickLookSession?

        init(panel: FilePreviewPanel) {
            quickLook = panel.nativeViewSessions.quickLook
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSView {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        return quickLook.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        quickLook.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.quickLook?.dismantle(nsView)
        coordinator.quickLook = nil
    }
}

private struct FilePreviewPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> FilePreviewPointerObserverView {
        let view = FilePreviewPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: FilePreviewPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

private final class FilePreviewPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                DispatchQueue.main.async { [weak self] in
                    self?.onPointerDown?()
                }
            }
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
