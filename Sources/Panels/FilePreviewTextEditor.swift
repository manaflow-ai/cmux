import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

// MARK: - Panel protocol (upstream addition)

@MainActor
protocol FilePreviewTextEditingPanel: AnyObject {
    var textContent: String { get }

    func attachTextView(_ textView: NSTextView)
    func retryPendingFocus()
    func updateTextContent(_ nextContent: String)
    @discardableResult
    func saveTextContent() -> Task<Void, Never>?
}

// MARK: - Language detection cache
//
// Plain struct in @State so detection (file-metadata I/O + CodeLanguage.detectLanguageFrom)
// runs exactly once per panel lifetime, not on every @ObservedObject re-render.

private struct FileLanguageCache {
    let language: CodeLanguage?
    init(url: URL) {
        language = SyntaxLanguageDetector.language(for: url)
    }
}

// MARK: - Router (chooses highlighted or plain editor based on file extension)

struct HighlightedFilePreviewRouter: View {
    @ObservedObject var panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool

    @State private var languageCache: FileLanguageCache

    init(
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        themeBackgroundColor: NSColor,
        themeForegroundColor: NSColor,
        drawsBackground: Bool
    ) {
        self.panel = panel
        self.isVisibleInUI = isVisibleInUI
        self.themeBackgroundColor = themeBackgroundColor
        self.themeForegroundColor = themeForegroundColor
        self.drawsBackground = drawsBackground
        self._languageCache = State(wrappedValue: FileLanguageCache(url: panel.fileURL))
    }

    var body: some View {
        if let language = languageCache.language {
            HighlightedFilePreviewEditor(
                panel: panel,
                isVisibleInUI: isVisibleInUI,
                themeBackgroundColor: themeBackgroundColor,
                themeForegroundColor: themeForegroundColor,
                language: language
            )
        } else {
            FilePreviewTextEditor(
                panel: panel,
                isVisibleInUI: isVisibleInUI,
                themeBackgroundColor: themeBackgroundColor,
                themeForegroundColor: themeForegroundColor,
                drawsBackground: drawsBackground
            )
        }
    }
}

// MARK: - Text storage + focus + zoom bridge
//
// SourceEditor's Binding<String> init is one-way (editor → parent only).
// NSTextStorage is shared by reference so external writes (async file load)
// are immediately visible in the text view.
//
// CodeEditTextView.setTextStorage() overwrites textStorage.delegate with its
// own MultiStorageDelegate, so we use TextViewCoordinator.textViewDidChangeText
// to propagate user edits to panel.textContent rather than NSTextStorageDelegate.
//
// The bridge also implements TextViewCoordinator to register the TextView with
// FilePreviewFocusCoordinator (keyboard focus) and manage the zoom event monitor.

@MainActor
final class HighlightedEditorBridge: NSObject, NSTextStorageDelegate, ObservableObject {
    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 36

    let storage = NSTextStorage()
    @Published private(set) var fontSize: CGFloat = defaultFontSize
    @Published private(set) var themeBackground: NSColor = .textBackgroundColor
    @Published private(set) var themeForeground: NSColor = .textColor
    private(set) var isApplyingExternalUpdate = false

    weak var panel: FilePreviewPanel? {
        didSet { registerFocusIfReady() }
    }
    private weak var textController: TextViewController? {
        didSet { registerFocusIfReady() }
    }

    override init() {
        super.init()
        storage.delegate = self
    }

    func setContent(_ newText: String) {
        guard storage.string != newText else { return }
        isApplyingExternalUpdate = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        isApplyingExternalUpdate = false
    }

    func updateThemeIfNeeded(background: NSColor, foreground: NSColor) {
        if !themeBackground.approximatelyEquals(background) { themeBackground = background }
        if !themeForeground.approximatelyEquals(foreground) { themeForeground = foreground }
    }

    func adjustFontSize(by factor: CGFloat) {
        setFontSize(fontSize * factor)
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        guard clamped.isFinite else { return }
        fontSize = clamped
    }

    // MARK: - Zoom event monitor
    //
    // SourceEditor's own NSScrollView consumes gesture events before they can
    // reach HighlightedEditorContainerView, so we use a local event monitor
    // anchored to the inner scroll view instead.

    private var zoomEventMonitor: Any?
    private weak var innerScrollView: NSScrollView?

    func installZoomMonitor(scrollView: NSScrollView) {
        innerScrollView = scrollView
        guard zoomEventMonitor == nil else { return }
        zoomEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel, .smartMagnify]) {
            [weak self] event in
            guard let self,
                  let sv = self.innerScrollView,
                  !sv.isHiddenOrHasHiddenAncestor,
                  let window = sv.window,
                  event.window === window else { return event }
            let loc = sv.convert(event.locationInWindow, from: nil)
            guard sv.bounds.contains(loc) else { return event }
            switch event.type {
            case .magnify:
                let factor = 1.0 + event.magnification
                if factor.isFinite && factor > 0 { self.adjustFontSize(by: factor) }
                return nil
            case .scrollWheel:
                guard FilePreviewInteraction.hasZoomModifier(event) else { return event }
                self.adjustFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
                return nil
            case .smartMagnify:
                if self.fontSize == HighlightedEditorBridge.defaultFontSize {
                    self.setFontSize(18)
                } else {
                    self.setFontSize(HighlightedEditorBridge.defaultFontSize)
                }
                return nil
            default:
                return event
            }
        }
    }

    func removeZoomMonitor() {
        if let m = zoomEventMonitor { NSEvent.removeMonitor(m); zoomEventMonitor = nil }
    }

    func reinstallZoomMonitorIfNeeded() {
        guard let sv = innerScrollView, zoomEventMonitor == nil else { return }
        installZoomMonitor(scrollView: sv)
    }

    // NSTextStorageDelegate is intentionally not used for edit detection:
    // CodeEditTextView replaces textStorage.delegate in setTextStorage().
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {}

    private func registerFocusIfReady() {
        guard let panel, let textView = textController?.textView else { return }
        panel.attachPreviewFocus(root: textView, primaryResponder: textView, intent: .textEditor)
        panel.retryPendingFocus()
    }
}

private extension NSColor {
    func approximatelyEquals(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return self == other
        }
        return abs(a.redComponent - b.redComponent) < 0.001 &&
               abs(a.greenComponent - b.greenComponent) < 0.001 &&
               abs(a.blueComponent - b.blueComponent) < 0.001 &&
               abs(a.alphaComponent - b.alphaComponent) < 0.001
    }
}

extension HighlightedEditorBridge: TextViewCoordinator {
    nonisolated func prepareCoordinator(controller: TextViewController) {
        Task { @MainActor [weak self] in
            self?.textController = controller
            self?.installZoomMonitor(scrollView: controller.scrollView)
        }
    }

    // Called after every user edit — correct hook since CodeEditTextView replaces
    // textStorage.delegate and our NSTextStorageDelegate callback would not fire.
    nonisolated func textViewDidChangeText(controller: TextViewController) {
        let text = controller.textView.string
        Task { @MainActor [weak self] in
            guard let self, !self.isApplyingExternalUpdate else { return }
            self.panel?.updateTextContent(text)
        }
    }

    nonisolated func destroy() {
        Task { @MainActor [weak self] in
            self?.removeZoomMonitor()
            self?.textController = nil
        }
    }
}

// MARK: - Highlighted editor container (AppKit event chain + SwiftUI SourceEditor)
//
// An NSView wrapper lets us intercept performKeyEquivalent (save shortcut) in the
// AppKit responder chain. Zoom gestures are handled by the event monitor above.

final class HighlightedEditorContainerView: NSView {
    weak var panel: FilePreviewPanel?
    var hostView: NSHostingView<HighlightedSourceEditorCore>?

    private let bridge: HighlightedEditorBridge
    private var pendingSaveChordPrefix: ShortcutStroke?

    init(bridge: HighlightedEditorBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        hostView?.frame = bounds
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let shouldSave = saveShortcutMatch(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        if shouldSave { panel?.saveTextContent() }
        return true
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }
        if let pending = pendingSaveChordPrefix {
            pendingSaveChordPrefix = nil
            guard pending == shortcut.firstStroke,
                  let second = shortcut.secondStroke else { return nil }
            return second.matches(event: event) ? true : nil
        }
        if shortcut.firstStroke.matches(event: event) {
            pendingSaveChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}

// MARK: - SwiftUI core (stable — created once, updated via @Published on bridge)

struct HighlightedSourceEditorCore: View {
    @ObservedObject var bridge: HighlightedEditorBridge
    let language: CodeLanguage
    @State private var editorState = SourceEditorState()

    var body: some View {
        SourceEditor(
            bridge.storage,
            language: language,
            configuration: makeConfiguration(),
            state: $editorState,
            coordinators: [bridge]
        )
    }

    private func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: makeSyntaxTheme(),
                font: .monospacedSystemFont(ofSize: bridge.fontSize, weight: .regular),
                wrapLines: false
            )
        )
    }

    private func makeSyntaxTheme() -> EditorTheme {
        let fg = bridge.themeForeground
        let bg = bridge.themeBackground
        let isDark = backgroundIsDark(bg)
        if isDark {
            return EditorTheme(
                text: .init(color: fg),
                insertionPoint: fg,
                invisibles: .init(color: fg.withAlphaComponent(0.25)),
                background: bg,
                lineHighlight: fg.withAlphaComponent(0.05),
                selection: fg.withAlphaComponent(0.2),
                keywords:   .init(color: NSColor(srgbRed: 0.337, green: 0.616, blue: 0.839, alpha: 1)),
                commands:   .init(color: NSColor(srgbRed: 0.867, green: 0.800, blue: 0.443, alpha: 1)),
                types:      .init(color: NSColor(srgbRed: 0.306, green: 0.788, blue: 0.690, alpha: 1)),
                attributes: .init(color: NSColor(srgbRed: 0.612, green: 0.863, blue: 0.996, alpha: 1)),
                variables:  .init(color: NSColor(srgbRed: 0.612, green: 0.863, blue: 0.996, alpha: 1)),
                values:     .init(color: NSColor(srgbRed: 0.710, green: 0.808, blue: 0.659, alpha: 1)),
                numbers:    .init(color: NSColor(srgbRed: 0.710, green: 0.808, blue: 0.659, alpha: 1)),
                strings:    .init(color: NSColor(srgbRed: 0.808, green: 0.569, blue: 0.471, alpha: 1)),
                characters: .init(color: NSColor(srgbRed: 0.808, green: 0.569, blue: 0.471, alpha: 1)),
                comments:   .init(color: NSColor(srgbRed: 0.420, green: 0.600, blue: 0.333, alpha: 1))
            )
        } else {
            return EditorTheme(
                text: .init(color: fg),
                insertionPoint: fg,
                invisibles: .init(color: fg.withAlphaComponent(0.25)),
                background: bg,
                lineHighlight: fg.withAlphaComponent(0.05),
                selection: fg.withAlphaComponent(0.2),
                keywords:   .init(color: NSColor(srgbRed: 0.000, green: 0.000, blue: 1.000, alpha: 1)),
                commands:   .init(color: NSColor(srgbRed: 0.686, green: 0.000, blue: 0.855, alpha: 1)),
                types:      .init(color: NSColor(srgbRed: 0.149, green: 0.498, blue: 0.600, alpha: 1)),
                attributes: .init(color: NSColor(srgbRed: 0.004, green: 0.063, blue: 0.502, alpha: 1)),
                variables:  .init(color: NSColor(srgbRed: 0.004, green: 0.063, blue: 0.502, alpha: 1)),
                values:     .init(color: NSColor(srgbRed: 0.036, green: 0.525, blue: 0.341, alpha: 1)),
                numbers:    .init(color: NSColor(srgbRed: 0.036, green: 0.525, blue: 0.341, alpha: 1)),
                strings:    .init(color: NSColor(srgbRed: 0.639, green: 0.082, blue: 0.082, alpha: 1)),
                characters: .init(color: NSColor(srgbRed: 0.639, green: 0.082, blue: 0.082, alpha: 1)),
                comments:   .init(color: NSColor(srgbRed: 0.000, green: 0.502, blue: 0.000, alpha: 1))
            )
        }
    }

    private func backgroundIsDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }
}

// MARK: - Highlighted file preview NSViewRepresentable

struct HighlightedFilePreviewEditor: NSViewRepresentable {
    @ObservedObject var panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let language: CodeLanguage

    func makeCoordinator() -> HighlightedEditorBridge { HighlightedEditorBridge() }

    func makeNSView(context: Context) -> HighlightedEditorContainerView {
        let bridge = context.coordinator
        bridge.updateThemeIfNeeded(background: themeBackgroundColor, foreground: themeForegroundColor)

        let container = HighlightedEditorContainerView(bridge: bridge)
        container.isHidden = !isVisibleInUI

        let hostView = NSHostingView(rootView: HighlightedSourceEditorCore(bridge: bridge, language: language))
        container.addSubview(hostView)
        container.hostView = hostView

        bridge.setContent(panel.textContent)
        return container
    }

    func updateNSView(_ container: HighlightedEditorContainerView, context: Context) {
        let bridge = context.coordinator
        container.isHidden = !isVisibleInUI
        container.panel = panel
        bridge.panel = panel
        bridge.setContent(panel.textContent)
        bridge.updateThemeIfNeeded(background: themeBackgroundColor, foreground: themeForegroundColor)
        if isVisibleInUI {
            bridge.reinstallZoomMonitorIfNeeded()
        } else {
            bridge.removeZoomMonitor()
        }
    }
}

// MARK: - Plain text editor (upstream generic version — used as fallback)

struct FilePreviewTextEditor<PanelModel>: NSViewRepresentable where PanelModel: ObservableObject & FilePreviewTextEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.isHidden = !isVisibleInUI
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = drawsBackground

        let textView = SavingTextView()
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.drawsBackground = drawsBackground
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.applyFilePreviewTextEditorInsets()
        textView.string = panel.textContent
        panel.attachTextView(textView)

        scrollView.documentView = textView
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel
        scrollView.isHidden = !isVisibleInUI
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        textView.panel = panel
        textView.applyFilePreviewTextEditorInsets()
        panel.attachTextView(textView)
        guard textView.string != panel.textContent else { return }
        context.coordinator.isApplyingPanelUpdate = true
        textView.string = panel.textContent
        context.coordinator.isApplyingPanelUpdate = false
    }

    static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = resolvedBackgroundColor
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: PanelModel
        var isApplyingPanelUpdate = false

        init(panel: PanelModel) {
            self.panel = panel
        }

        deinit {}

        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? NSTextView else { return }
            panel.updateTextContent(textView.string)
        }
    }
}

enum FilePreviewTextEditorLayout {
    static let textContainerInset = NSSize(width: 12, height: 10)
    static let lineFragmentPadding: CGFloat = 0
}

extension NSTextView {
    func applyFilePreviewTextEditorInsets() {
        let targetInset = FilePreviewTextEditorLayout.textContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

final class SavingTextView: NSTextView {
    private static let defaultPreviewFontSize: CGFloat = 13
    private static let minimumPreviewFontSize: CGFloat = 8
    private static let maximumPreviewFontSize: CGFloat = 36

    weak var panel: (any FilePreviewTextEditingPanel)?
    private var previewFontSize: CGFloat = 13
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?

    deinit {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        guard let shouldSave = saveShortcutMatch(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        if shouldSave {
            panel?.saveTextContent()
        }
        return true
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustPreviewFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if previewFontSize == Self.defaultPreviewFontSize {
            setPreviewFontSize(18)
        } else {
            setPreviewFontSize(Self.defaultPreviewFontSize)
        }
    }

    private func adjustPreviewFontSize(by factor: CGFloat) {
        setPreviewFontSize(previewFontSize * factor)
    }

    private func setPreviewFontSize(_ nextFontSize: CGFloat) {
        let clamped = min(max(nextFontSize, Self.minimumPreviewFontSize), Self.maximumPreviewFontSize)
        guard clamped.isFinite else { return }
        previewFontSize = clamped
        let nextFont = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        font = nextFont
        typingAttributes[.font] = nextFont
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveShortcutChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }

        if let pendingPrefix = pendingSaveShortcutChordPrefix {
            pendingSaveShortcutChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else {
                return nil
            }
            return secondStroke.matches(event: event) ? true : nil
        }

        if shortcut.firstStroke.matches(event: event) {
            pendingSaveShortcutChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}
