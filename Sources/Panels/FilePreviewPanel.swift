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
final class FilePreviewPanel: Panel, ObservableObject, FilePreviewTextEditingPanel, FilePreviewNativeHosting {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
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
    weak var textView: NSTextView?
    let focusCoordinator: FilePreviewFocusCoordinator
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

    func syncKeyboardFocusAfterFirstResponderChange(in window: NSWindow?) {
        AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: window)
    }

    func makeFileOpenChromeMenu(for url: URL) -> AnyView {
        AnyView(FileExternalOpenMenu(fileURL: url, style: .chrome))
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
                withAnimation(segment.curve.animation(duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
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
        let nativeBackground = FilePreviewNativeBackground()
        let resolvedBackgroundColor = nativeBackground.resolvedColor(
            backgroundColor: previewBackgroundColor,
            drawsBackground: drawsPreviewBackground
        )
        nativeBackground.applyRootLayer(
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
        let viewport = FilePreviewViewport()
        let anchorRatio = CGPoint(
            x: viewport.normalizedAnchorRatio(
                anchorInDocument.x - oldImageFrame.minX,
                length: oldImageFrame.width
            ),
            y: viewport.normalizedAnchorRatio(
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
