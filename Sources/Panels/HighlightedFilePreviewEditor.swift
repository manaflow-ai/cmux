import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

// MARK: - Text storage + focus + zoom bridge
//
// SourceEditor's Binding<String> init is one-way (editor -> parent only).
// NSTextStorage is shared by reference so external writes (async file load)
// are immediately visible in the text view.
//
// CodeEditTextView.setTextStorage() overwrites textStorage.delegate with its
// own MultiStorageDelegate, so we use CodeEditTextView.TextViewDelegate to
// propagate user edits to panel.textContent rather than NSTextStorageDelegate.
//
// The bridge also implements TextViewCoordinator to register the TextView with
// FilePreviewFocusCoordinator (keyboard focus) and manage the zoom event monitor.

@MainActor
final class HighlightedEditorBridge: NSObject, @preconcurrency NSTextStorageDelegate, ObservableObject {
    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 36

    let storage = NSTextStorage()
    @Published private(set) var fontSize: CGFloat = defaultFontSize
    @Published private(set) var themeBackground: NSColor = .textBackgroundColor
    @Published private(set) var themeForeground: NSColor = .textColor
    @Published private(set) var drawsBackground: Bool = true
    private(set) var isApplyingExternalUpdate = false

    weak var panel: FilePreviewPanel? {
        didSet {
            guard oldValue !== panel else { return }
            registerFocusIfReady()
        }
    }
    private weak var textController: TextViewController? {
        didSet {
            guard oldValue !== textController else { return }
            registerFocusIfReady()
        }
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

    func updateThemeIfNeeded(background: NSColor, foreground: NSColor, drawsBackground draws: Bool) {
        if !themeBackground.approximatelyEquals(background) { themeBackground = background }
        if !themeForeground.approximatelyEquals(foreground) { themeForeground = foreground }
        if self.drawsBackground != draws { self.drawsBackground = draws }
    }

    func adjustFontSize(by factor: CGFloat) {
        setFontSize(fontSize * factor)
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        guard clamped.isFinite else { return }
        fontSize = clamped
    }

    // MARK: - Local event monitor
    //
    // SourceEditor's own NSScrollView consumes gesture events before they can
    // reach HighlightedEditorContainerView, so we use a local event monitor for
    // zoom. The same monitor catches the save shortcut while the CodeEdit text
    // view is first responder so the inner editor cannot swallow it first.

    // localEventMonitor may be accessed from destroy() off the main actor as well as
    // from @MainActor install/remove methods. NSLock serializes the read-check-remove-nil
    // sequence so the token is never passed to NSEvent.removeMonitor twice.
    // nonisolated(unsafe) is justified because every access goes through eventMonitorLock.
    private let eventMonitorLock = NSLock()
    private nonisolated(unsafe) var localEventMonitor: Any?
    private nonisolated(unsafe) var coordinatorDestroyed = false
    private weak var innerScrollView: NSScrollView?
    private var pendingSaveChordPrefix: ShortcutStroke?
    private var isVisibleInUI = true

    func installLocalEventMonitor(scrollView: NSScrollView) {
        innerScrollView = scrollView
        guard isVisibleInUI else { return }

        eventMonitorLock.lock()
        if coordinatorDestroyed || localEventMonitor != nil {
            eventMonitorLock.unlock()
            return
        }
        eventMonitorLock.unlock()

        // NSEvent.addLocalMonitorForEvents handlers fire on the main thread (documented),
        // so MainActor.assumeIsolated lets the closure body call our @MainActor-isolated
        // properties and methods without crossing the actor at compile time.
        let token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .magnify, .scrollWheel, .smartMagnify]) {
            [weak self] event -> NSEvent? in
            let handled = MainActor.assumeIsolated {
                self?.handleLocalEvent(event) ?? false
            }
            return handled ? nil : event
        }
        eventMonitorLock.lock()
        if !coordinatorDestroyed, localEventMonitor == nil {
            localEventMonitor = token
            eventMonitorLock.unlock()
        } else {
            eventMonitorLock.unlock()
            if let token = token { NSEvent.removeMonitor(token) }
        }
    }

    func removeLocalEventMonitor() {
        eventMonitorLock.lock()
        let token = localEventMonitor
        localEventMonitor = nil
        eventMonitorLock.unlock()
        if let token = token { NSEvent.removeMonitor(token) }
    }

    func reinstallLocalEventMonitorIfNeeded() {
        eventMonitorLock.lock()
        let alreadyInstalled = localEventMonitor != nil
        let destroyed = coordinatorDestroyed
        eventMonitorLock.unlock()
        guard isVisibleInUI,
              let sv = innerScrollView,
              !alreadyInstalled,
              !destroyed else { return }
        installLocalEventMonitor(scrollView: sv)
    }

    func setVisibleInUI(_ visible: Bool) {
        guard isVisibleInUI != visible else {
            if visible { reinstallLocalEventMonitorIfNeeded() }
            return
        }

        isVisibleInUI = visible
        pendingSaveChordPrefix = nil

        if visible {
            registerFocusIfReady()
            reinstallLocalEventMonitorIfNeeded()
        } else {
            removeLocalEventMonitor()
            unregisterFocusIfNeeded()
        }
    }

    var isLocalEventMonitorInstalledForTesting: Bool {
        eventMonitorLock.lock()
        let installed = localEventMonitor != nil
        eventMonitorLock.unlock()
        return installed
    }

    private func isCoordinatorDestroyed() -> Bool {
        eventMonitorLock.lock()
        let destroyed = coordinatorDestroyed
        eventMonitorLock.unlock()
        return destroyed
    }

    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            guard let textView = textController?.textView,
                  !textView.isHiddenOrHasHiddenAncestor,
                  textView.window?.firstResponder === textView,
                  event.window === textView.window else { return false }
            return handleSaveShortcut(event: event)
        case .magnify, .scrollWheel, .smartMagnify:
            return handleZoomEvent(event)
        default:
            return false
        }
    }

    private func handleZoomEvent(_ event: NSEvent) -> Bool {
        guard let sv = innerScrollView,
              !sv.isHiddenOrHasHiddenAncestor,
              let window = sv.window,
              event.window === window else { return false }
        let loc = sv.convert(event.locationInWindow, from: nil)
        guard sv.bounds.contains(loc) else { return false }
        switch event.type {
        case .magnify:
            let factor = 1.0 + event.magnification
            if factor.isFinite && factor > 0 { adjustFontSize(by: factor) }
            return true
        case .scrollWheel:
            guard FilePreviewInteraction.hasZoomModifier(event) else { return false }
            adjustFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
            return true
        case .smartMagnify:
            if fontSize == HighlightedEditorBridge.defaultFontSize {
                setFontSize(18)
            } else {
                setFontSize(HighlightedEditorBridge.defaultFontSize)
            }
            return true
        default:
            return false
        }
    }

    func handleSaveShortcut(event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              isVisibleInUI,
              !isCoordinatorDestroyed() else {
            pendingSaveChordPrefix = nil
            return false
        }
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveChordPrefix = nil
            guard shortcut.matches(event: event) else { return false }
            panel?.saveTextContent()
            return true
        }
        if let pending = pendingSaveChordPrefix {
            pendingSaveChordPrefix = nil
            guard pending == shortcut.firstStroke,
                  let second = shortcut.secondStroke,
                  second.matches(event: event) else { return false }
            panel?.saveTextContent()
            return true
        }
        if shortcut.firstStroke.matches(event: event) {
            pendingSaveChordPrefix = shortcut.firstStroke
            return true
        }
        return false
    }

    func applyUserEditedText(_ text: String) {
        guard !isApplyingExternalUpdate, !isCoordinatorDestroyed() else { return }
        panel?.updateTextContent(text)
    }

    func retryPendingFocus() {
        guard isVisibleInUI else { return }
        panel?.retryPendingFocus()
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
        guard isVisibleInUI,
              let panel,
              let textView = textController?.textView else { return }
        panel.attachTextInsertionTarget(textView)
        panel.attachPreviewFocus(root: textView, primaryResponder: textView, intent: .textEditor)
        panel.retryPendingFocus()
    }

    private func unregisterFocusIfNeeded() {
        guard let panel, let textView = textController?.textView else { return }
        if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        panel.detachTextInsertionTarget(textView)
        panel.detachPreviewFocus(root: textView, primaryResponder: textView, intent: .textEditor)
    }
}

extension TextView: FilePreviewTextInsertionTarget {
    var filePreviewCurrentText: String { string }

    func focusFilePreviewTextTarget() {
        window?.makeFirstResponder(self)
    }

    func insertFilePreviewText(_ text: String) {
        insertText(text, replacementRange: selectedRange())
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
        MainActor.assumeIsolated {
            guard !isCoordinatorDestroyed() else { return }
            textController = controller
            installLocalEventMonitor(scrollView: controller.scrollView)
        }
    }

    nonisolated func destroy() {
        // Remove the event monitor synchronously through the lock so we never
        // double-call NSEvent.removeMonitor with the same token. SwiftUI releases
        // the coordinator on the same tick that calls destroy(); a deferred Task
        // with [weak self] would find self nil and leak the monitor.
        eventMonitorLock.lock()
        coordinatorDestroyed = true
        let token = localEventMonitor
        localEventMonitor = nil
        eventMonitorLock.unlock()
        if let token = token { NSEvent.removeMonitor(token) }
    }
}

extension HighlightedEditorBridge: TextViewDelegate {
    nonisolated func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        MainActor.assumeIsolated {
            applyUserEditedText(textView.string)
        }
    }
}

// MARK: - Highlighted editor container (AppKit event chain + SwiftUI SourceEditor)
//
// An NSView wrapper lets us intercept performKeyEquivalent (save shortcut) in the
// AppKit responder chain. Zoom gestures are handled by the event monitor above.

final class HighlightedEditorContainerView: NSView {
    var hostView: NSHostingView<HighlightedSourceEditorCore>?

    private let bridge: HighlightedEditorBridge

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bridge.retryPendingFocus()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        return bridge.handleSaveShortcut(event: event) || super.performKeyEquivalent(with: event)
    }
}

// MARK: - SwiftUI core (stable - created once, updated via @Published on bridge)

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
        let bg = bridge.drawsBackground ? bridge.themeBackground : .clear
        // Always derive light/dark from the actual theme background, never from the
        // resolved clear color, otherwise transparent dark terminals would get the
        // light syntax palette.
        let isDark = backgroundIsDark(bridge.themeBackground)
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
    let drawsBackground: Bool
    let language: CodeLanguage

    func makeCoordinator() -> HighlightedEditorBridge { HighlightedEditorBridge() }

    func makeNSView(context: Context) -> HighlightedEditorContainerView {
        let bridge = context.coordinator
        bridge.setVisibleInUI(isVisibleInUI)
        bridge.updateThemeIfNeeded(background: themeBackgroundColor, foreground: themeForegroundColor, drawsBackground: drawsBackground)

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
        bridge.setVisibleInUI(isVisibleInUI)
        bridge.panel = panel
        bridge.setContent(panel.textContent)
        bridge.updateThemeIfNeeded(background: themeBackgroundColor, foreground: themeForegroundColor, drawsBackground: drawsBackground)
    }

    static func dismantleNSView(_ container: HighlightedEditorContainerView, coordinator: HighlightedEditorBridge) {
        coordinator.destroy()
    }
}
