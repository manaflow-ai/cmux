import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Command palette window overlay controller
private var commandPaletteWindowOverlayKey: UInt8 = 0
let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")
func windowContentOverlayInstallationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
    if let glassTarget = WindowGlassEffect.portalInstallationTarget(for: window) {
        return glassTarget
    }

    guard let contentView = window.contentView,
          let themeFrame = contentView.superview else {
        return nil
    }
    return (themeFrame, contentView)
}

enum CommandPaletteOverlayPromotionPolicy {
    static func shouldPromote(previouslyVisible: Bool, isVisible: Bool) -> Bool {
        isVisible && !previouslyVisible
    }
}

@MainActor
final class CommandPaletteOverlayContainerView: NSView {
    var capturesMouseEvents = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesMouseEvents else { return nil }
        return super.hitTest(point)
    }
}

#if DEBUG
func debugCommandPaletteWindowSummary(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    let ident = window.identifier?.rawValue ?? "nil"
    return "num=\(window.windowNumber) ident=\(ident) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
}

private func debugCommandPaletteNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func debugCommandPaletteModifierFlagsSummary(_ flags: NSEvent.ModifierFlags) -> String {
    let normalized = debugCommandPaletteNormalizedModifierFlags(flags)
    var parts: [String] = []
    if normalized.contains(.command) { parts.append("cmd") }
    if normalized.contains(.shift) { parts.append("shift") }
    if normalized.contains(.option) { parts.append("opt") }
    if normalized.contains(.control) { parts.append("ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func debugCommandPaletteKeyEventSummary(_ event: NSEvent) -> String {
    let chars = event.characters.map(String.init(reflecting:)) ?? "nil"
    let charsIgnoring = event.charactersIgnoringModifiers.map(String.init(reflecting:)) ?? "nil"
    return
        "type=\(event.type) keyCode=\(event.keyCode) flags=\(debugCommandPaletteModifierFlagsSummary(event.modifierFlags)) " +
        "chars=\(chars) charsIgnoring=\(charsIgnoring)"
}

func debugCommandPaletteTextPreview(_ text: String, limit: Int = 120) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    let prefix = escaped.prefix(limit)
    return "\(prefix)..."
}

func debugCommandPaletteResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }

    let typeName = String(describing: type(of: responder))
    if let textView = responder as? NSTextView {
        let selection = textView.selectedRange()
        return "\(typeName){fieldEditor=\(textView.isFieldEditor ? 1 : 0) editable=\(textView.isEditable ? 1 : 0) selectable=\(textView.isSelectable ? 1 : 0) hidden=\(textView.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textView.string as NSString).length) sel=\(selection.location):\(selection.length)}"
    }

    if let textField = responder as? NSTextField {
        return "\(typeName){editable=\(textField.isEditable ? 1 : 0) enabled=\(textField.isEnabled ? 1 : 0) hidden=\(textField.isHiddenOrHasHiddenAncestor ? 1 : 0) len=\((textField.stringValue as NSString).length)}"
    }

    if let view = responder as? NSView {
        return "\(typeName){hidden=\(view.isHiddenOrHasHiddenAncestor ? 1 : 0)}"
    }

    return typeName
}
#endif

@MainActor
final class WindowCommandPaletteOverlayController: NSObject {
    weak var window: NSWindow?
    let containerView = CommandPaletteOverlayContainerView(frame: .zero)
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainerView: NSView?
    weak var installedReferenceView: NSView?
    private var focusLockTimer: DispatchSourceTimer?
    private var scheduledFocusWorkItem: DispatchWorkItem?
    private var isPaletteVisible = false
    private var hasMountedPaletteRootView = false
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var windowDidResignKeyObserver: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.capturesMouseEvents = false
        containerView.identifier = commandPaletteOverlayContainerIdentifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        _ = ensureInstalled()
        installWindowKeyObservers()
    }

    @discardableResult
    func ensureInstalled() -> Bool {
        guard let window,
              let target = windowContentOverlayInstallationTarget(for: window) else { return false }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = target.container
            installedReferenceView = target.reference
#if DEBUG
            cmuxDebugLog(
                "palette.overlay.install container=\(String(describing: type(of: target.container))) " +
                "reference=\(String(describing: type(of: target.reference))) " +
                "glass=\(WindowGlassEffect.portalInstallationTarget(for: window) != nil ? 1 : 0)"
            )
#endif
        }

        return true
    }

    private func promoteOverlayAboveSiblingsIfNeeded() {
        guard let container = installedContainerView,
              containerView.superview === container else { return }
        container.addSubview(containerView, positioned: .above, relativeTo: nil)
    }

    private func isPaletteResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let view = responder as? NSView, view.isDescendant(of: containerView) {
            return true
        }

        if let textView = responder as? NSTextView {
            if let delegateView = textView.delegate as? NSView,
               delegateView.isDescendant(of: containerView) {
                return true
            }
        }

        return false
    }

    private func isPaletteFieldEditor(_ textView: NSTextView) -> Bool {
        guard textView.isFieldEditor else { return false }

        if let delegateView = textView.delegate as? NSView,
           delegateView.isDescendant(of: containerView) {
            return true
        }

        // SwiftUI text fields can keep a field editor delegate that isn't an NSView.
        // Fall back to validating editor ownership from the mounted palette text field.
        if let textField = firstEditableTextField(in: hostingView),
           textField.currentEditor() === textView {
            return true
        }

        return false
    }

    private func isPaletteMultilineTextView(_ textView: NSTextView) -> Bool {
        guard !textView.isFieldEditor,
              textView.isEditable,
              textView.isSelectable,
              !textView.isHiddenOrHasHiddenAncestor,
              textView.isDescendant(of: containerView) else { return false }
        return true
    }

    private func isPaletteTextInputFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let textView = responder as? NSTextView {
            return isPaletteFieldEditor(textView) || isPaletteMultilineTextView(textView)
        }

        if let textField = responder as? NSTextField {
            return textField.isDescendant(of: containerView)
        }

        return false
    }

    private func firstEditableTextInput(in view: NSView) -> NSResponder? {
        if let textField = view as? NSTextField,
           textField.isEditable,
           textField.isEnabled,
           !textField.isHiddenOrHasHiddenAncestor {
            return textField
        }

        if let textView = view as? NSTextView,
           !textView.isFieldEditor,
           textView.isEditable,
           textView.isSelectable,
           !textView.isHiddenOrHasHiddenAncestor {
            return textView
        }

        for subview in view.subviews {
            if let match = firstEditableTextInput(in: subview) {
                return match
            }
        }
        return nil
    }

    private func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField,
           textField.isEditable,
           textField.isEnabled,
           !textField.isHiddenOrHasHiddenAncestor {
            return textField
        }

        for subview in view.subviews {
            if let match = firstEditableTextField(in: subview) {
                return match
            }
        }
        return nil
    }

    private func focusPaletteTextInput(in window: NSWindow) -> Bool {
        guard let input = firstEditableTextInput(in: hostingView) else {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.direct missingInput window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "palette.focus.direct attempt window={\(debugCommandPaletteWindowSummary(window))} " +
            "input=\(debugCommandPaletteResponderSummary(input)) " +
            "frBefore=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        guard window.makeFirstResponder(input) else {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.direct failedMakeFirstResponder window={\(debugCommandPaletteWindowSummary(window))} " +
                "input=\(debugCommandPaletteResponderSummary(input)) " +
                "frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return false
        }

        if let textView = input as? NSTextView, !textView.isFieldEditor {
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
        } else {
            normalizeSelectionAfterProgrammaticFocus()
        }

        let didSettle = isPaletteTextInputFirstResponder(window.firstResponder)
#if DEBUG
        cmuxDebugLog(
            "palette.focus.direct settled window={\(debugCommandPaletteWindowSummary(window))} " +
            "didSettle=\(didSettle ? 1 : 0) frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        return didSettle
    }

    private func scheduleFocusIntoPalette(retries: Int = 4) {
#if DEBUG
        if let window {
            cmuxDebugLog(
                "palette.focus.schedule retries=\(retries) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
        } else {
            cmuxDebugLog("palette.focus.schedule retries=\(retries) window=nil")
        }
#endif
        scheduledFocusWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledFocusWorkItem = nil
            self?.focusIntoPalette(retries: retries)
        }
        scheduledFocusWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func focusIntoPalette(retries: Int) {
        guard let window else { return }
#if DEBUG
        cmuxDebugLog(
            "palette.focus.retry start retries=\(retries) " +
            "window={\(debugCommandPaletteWindowSummary(window))} " +
            "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        if isPaletteTextInputFirstResponder(window.firstResponder) {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.retry alreadyFocused window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return
        }

        if focusPaletteTextInput(in: window) {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.retry directSuccess retries=\(retries) " +
                "window={\(debugCommandPaletteWindowSummary(window))}"
            )
#endif
            return
        }

        let containerFocused = window.makeFirstResponder(containerView)
#if DEBUG
        cmuxDebugLog(
            "palette.focus.retry containerResult retries=\(retries) " +
            "window={\(debugCommandPaletteWindowSummary(window))} " +
            "didFocusContainer=\(containerFocused ? 1 : 0) " +
            "frAfterContainer=\(debugCommandPaletteResponderSummary(window.firstResponder))"
        )
#endif
        if containerFocused {
            if focusPaletteTextInput(in: window) {
#if DEBUG
                cmuxDebugLog(
                    "palette.focus.retry containerAssistedSuccess retries=\(retries) " +
                    "window={\(debugCommandPaletteWindowSummary(window))}"
                )
#endif
                return
            }
        }

        guard retries > 0 else {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.retry exhausted window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            return
        }
#if DEBUG
        cmuxDebugLog(
            "palette.focus.retry reschedule nextRetries=\(retries - 1) " +
            "window={\(debugCommandPaletteWindowSummary(window))}"
        )
#endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.focusIntoPalette(retries: retries - 1)
        }
    }

    private func installWindowKeyObservers() {
        guard let window else { return }
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusLockForWindowState()
            }
        }
        windowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusLockForWindowState()
            }
        }
    }

    private func updateFocusLockForWindowState() {
        guard let window else {
            stopFocusLockTimer()
            return
        }
        guard isPaletteVisible else {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.lock inactive visible=0 window={\(debugCommandPaletteWindowSummary(window))}"
            )
#endif
            stopFocusLockTimer()
            return
        }

        guard window.isKeyWindow else {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.lock keyWindowMissing window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            stopFocusLockTimer()
            if isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            return
        }

        startFocusLockTimer()
        if !isPaletteTextInputFirstResponder(window.firstResponder) {
#if DEBUG
            cmuxDebugLog(
                "palette.focus.lock requestRestore window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            scheduleFocusIntoPalette(retries: 8)
        }
    }

    private func startFocusLockTimer() {
        guard focusLockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(12))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.stopFocusLockTimer()
                return
            }
            if self.isPaletteTextInputFirstResponder(window.firstResponder) {
                return
            }
            self.focusIntoPalette(retries: 1)
        }
        focusLockTimer = timer
        timer.resume()
    }

    private func stopFocusLockTimer() {
        focusLockTimer?.cancel()
        focusLockTimer = nil
        scheduledFocusWorkItem?.cancel()
        scheduledFocusWorkItem = nil
    }

    private func normalizeSelectionAfterProgrammaticFocus() {
        guard let window,
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else { return }

        let text = editor.string
        let length = (text as NSString).length
        let selection = editor.selectedRange()
        guard length > 0 else { return }
        guard selection.location == 0, selection.length == length else { return }

        // Keep commands-mode prefix semantics stable after focus re-assertions:
        // if AppKit selected the entire query (e.g. ">foo"), restore caret-at-end
        // so the next keystroke appends instead of replacing and switching modes.
        guard text.hasPrefix(">") else { return }
        editor.setSelectedRange(NSRange(location: length, length: 0))
    }

    func update(
        isVisible: Bool,
        makeRootView: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    ) {
        let wasVisible = isPaletteVisible
        if !isVisible, !wasVisible, !hasMountedPaletteRootView, containerView.isHidden {
            return
        }

        guard ensureInstalled() else { return }
        let shouldPromote = CommandPaletteOverlayPromotionPolicy.shouldPromote(
            previouslyVisible: wasVisible,
            isVisible: isVisible
        )
#if DEBUG
        if let window {
            cmuxDebugLog(
                "palette.overlay.update visible=\(isVisible ? 1 : 0) promote=\(shouldPromote ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
        } else {
            cmuxDebugLog("palette.overlay.update visible=\(isVisible ? 1 : 0) promote=\(shouldPromote ? 1 : 0) window=nil")
        }
#endif
        isPaletteVisible = isVisible
        if isVisible {
            hostingView.rootView = makeRootView()
            hasMountedPaletteRootView = true
            containerView.capturesMouseEvents = true
            containerView.isHidden = false
            containerView.alphaValue = 1
            if shouldPromote {
                promoteOverlayAboveSiblingsIfNeeded()
            }
            updateFocusLockForWindowState()
        } else {
            stopFocusLockTimer()
            if let window, isPaletteResponder(window.firstResponder) {
                _ = window.makeFirstResponder(nil)
            }
            hostingView.rootView = AnyView(EmptyView())
            hasMountedPaletteRootView = false
            containerView.capturesMouseEvents = false
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }

    func underlyingResponder(atWindowPoint windowPoint: NSPoint) -> NSResponder? {
        guard let window,
              let target = windowContentOverlayInstallationTarget(for: window) else {
            return nil
        }

        let previousCapturesMouseEvents = containerView.capturesMouseEvents
        containerView.capturesMouseEvents = false
        defer {
            containerView.capturesMouseEvents = previousCapturesMouseEvents
        }

        let pointInContainer = target.container.convert(windowPoint, from: nil)
        return target.container.hitTest(pointInContainer)
    }
}

@MainActor
func commandPaletteWindowOverlayController(for window: NSWindow) -> WindowCommandPaletteOverlayController {
    if let existing = objc_getAssociatedObject(window, &commandPaletteWindowOverlayKey) as? WindowCommandPaletteOverlayController {
        return existing
    }
    let controller = WindowCommandPaletteOverlayController(window: window)
    objc_setAssociatedObject(window, &commandPaletteWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
}

func commandPaletteOwningWebView(for responder: NSResponder?) -> WKWebView? {
    guard let responder else { return nil }

    if let webView = responder as? WKWebView {
        return webView
    }

    if let view = responder as? NSView {
        var current: NSView? = view
        while let candidate = current {
            if let webView = candidate as? WKWebView {
                return webView
            }
            current = candidate.superview
        }
    }

    if let textView = responder as? NSTextView,
       let delegateView = textView.delegate as? NSView,
       let webView = commandPaletteOwningWebView(for: delegateView) {
        return webView
    }

    var currentResponder = responder.nextResponder
    while let next = currentResponder {
        if let webView = commandPaletteOwningWebView(for: next) {
            return webView
        }
        currentResponder = next.nextResponder
    }

    return nil
}

