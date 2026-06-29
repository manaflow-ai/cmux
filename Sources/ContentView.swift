import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Bonsplit
import Combine
import CmuxSidebarInterpreterClient
import CmuxTerminal
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettingsUI
import CmuxSidebar
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

var fileDropOverlayKey: UInt8 = 0
private var commandPaletteWindowOverlayKey: UInt8 = 0
private var tmuxWorkspacePaneWindowOverlayKey: UInt8 = 0
let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")
let tmuxWorkspacePaneOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.tmuxWorkspacePane.overlay.container")

@MainActor
private final class CommandPaletteOverlayContainerView: NSView {
    var capturesMouseEvents = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesMouseEvents else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class PassthroughWindowOverlayContainerView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

#if DEBUG
private func debugCommandPaletteWindowSummary(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    let ident = window.identifier?.rawValue ?? "nil"
    return "num=\(window.windowNumber) ident=\(ident) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
}

private func debugCommandPaletteNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

private func debugCommandPaletteModifierFlagsSummary(_ flags: NSEvent.ModifierFlags) -> String {
    let normalized = debugCommandPaletteNormalizedModifierFlags(flags)
    var parts: [String] = []
    if normalized.contains(.command) { parts.append("cmd") }
    if normalized.contains(.shift) { parts.append("shift") }
    if normalized.contains(.option) { parts.append("opt") }
    if normalized.contains(.control) { parts.append("ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

private func debugCommandPaletteKeyEventSummary(_ event: NSEvent) -> String {
    let chars = event.characters.map(String.init(reflecting:)) ?? "nil"
    let charsIgnoring = event.charactersIgnoringModifiers.map(String.init(reflecting:)) ?? "nil"
    return
        "type=\(event.type) keyCode=\(event.keyCode) flags=\(debugCommandPaletteModifierFlagsSummary(event.modifierFlags)) " +
        "chars=\(chars) charsIgnoring=\(charsIgnoring)"
}

private func debugCommandPaletteTextPreview(_ text: String, limit: Int = 120) -> String {
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

private func debugCommandPaletteResponderSummary(_ responder: NSResponder?) -> String {
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
private final class WindowCommandPaletteOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = CommandPaletteOverlayContainerView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
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
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition
                .contentOverlayTargetResolver
                .installationTarget(for: window) else { return false }

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
                "glass=\(chromeComposition.glassEffect.portalInstallationTarget(for: window) != nil ? 1 : 0)"
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
        let shouldPromote = CommandPaletteOverlayPromotionPolicy(
            previouslyVisible: wasVisible,
            isVisible: isVisible
        ).shouldPromote
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
              let target = chromeComposition
                .contentOverlayTargetResolver
                .installationTarget(for: window) else {
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
private func commandPaletteWindowOverlayController(for window: NSWindow) -> WindowCommandPaletteOverlayController {
    if let existing = objc_getAssociatedObject(window, &commandPaletteWindowOverlayKey) as? WindowCommandPaletteOverlayController {
        return existing
    }
    let controller = WindowCommandPaletteOverlayController(window: window)
    objc_setAssociatedObject(window, &commandPaletteWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
}

@MainActor
private final class WindowTmuxWorkspacePaneOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = PassthroughWindowOverlayContainerView(frame: .zero)
    private let model = TmuxWorkspacePaneOverlayModel()
    private let hostingView: NSHostingView<TmuxWorkspacePaneOverlayView>
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedReferenceView: NSView?
    private var lastRenderState: TmuxWorkspacePaneOverlayRenderState?

    init(window: NSWindow) {
        self.window = window
        self.hostingView = NSHostingView(
            rootView: TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
        )
        super.init()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.identifier = tmuxWorkspacePaneOverlayContainerIdentifier
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
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition
                .contentOverlayTargetResolver
                .installationTarget(for: window) else { return false }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: target.reference)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedReferenceView = target.reference
        }

        return true
    }

    func update(state: TmuxWorkspacePaneOverlayRenderState?) {
        guard ensureInstalled() else { return }

        if state == nil, lastRenderState == nil, containerView.isHidden {
            return
        }
        if let state, state == lastRenderState {
            return
        }

        if let state {
            lastRenderState = state
            model.apply(state)
            hostingView.rootView = TmuxWorkspacePaneOverlayView(
                unreadRects: model.unreadRects,
                flashRect: model.flashRect,
                flashStartedAt: model.flashStartedAt,
                flashReason: model.flashReason
            )
            containerView.alphaValue = 1
            containerView.isHidden = false
        } else {
            lastRenderState = nil
            model.clear()
            hostingView.rootView = TmuxWorkspacePaneOverlayView(
                unreadRects: [],
                flashRect: nil,
                flashStartedAt: nil,
                flashReason: nil
            )
            containerView.alphaValue = 0
            containerView.isHidden = true
        }
    }
}

@MainActor
private func tmuxWorkspacePaneWindowOverlayController(for window: NSWindow, createIfNeeded: Bool) -> WindowTmuxWorkspacePaneOverlayController? {
    if let existing = objc_getAssociatedObject(window, &tmuxWorkspacePaneWindowOverlayKey) as? WindowTmuxWorkspacePaneOverlayController {
        return existing
    }
    guard createIfNeeded else { return nil }
    let controller = WindowTmuxWorkspacePaneOverlayController(window: window)
    objc_setAssociatedObject(window, &tmuxWorkspacePaneWindowOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
}
private func commandPaletteOwningWebView(for responder: NSResponder?) -> WKWebView? {
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

// Lifted to `CmuxFoundation.WorkspaceMountPlan` / `MountedWorkspacePresentation`
// (ContentView decomposition). These typealiases keep call sites short.
typealias WorkspaceMountPlan = CmuxFoundation.WorkspaceMountPlan
typealias MountedWorkspacePresentation = CmuxFoundation.MountedWorkspacePresentation

/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.
private func findFileDropOverlayView(in root: NSView?) -> FileDropOverlayView? {
    guard let root else { return nil }
    if let overlay = root as? FileDropOverlayView {
        return overlay
    }
    for subview in root.subviews {
        if let overlay = findFileDropOverlayView(in: subview) {
            return overlay
        }
    }
    return nil
}

private func configureFileDropOverlay(_ overlay: FileDropOverlayView, tabManager: TabManager) {
    overlay.onDrop = { [weak tabManager] urls in
        MainActor.assumeIsolated {
            guard let tabManager, let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return false }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }
}

private func attachFileDropOverlay(
    _ overlay: FileDropOverlayView,
    to referenceView: NSView,
    in containerView: NSView
) {
    overlay.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(overlay, positioned: .above, relativeTo: referenceView)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: referenceView.topAnchor),
        overlay.bottomAnchor.constraint(equalTo: referenceView.bottomAnchor),
        overlay.leadingAnchor.constraint(equalTo: referenceView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: referenceView.trailingAnchor)
    ])
}

private func fileDropOverlay(
    _ overlay: FileDropOverlayView,
    isAttachedTo referenceView: NSView,
    in containerView: NSView
) -> Bool {
    guard overlay.superview === containerView else { return false }
    let requiredAttributes: [NSLayoutConstraint.Attribute] = [.top, .bottom, .leading, .trailing]
    return requiredAttributes.allSatisfy { attribute in
        containerView.constraints.contains { constraint in
            let firstView = constraint.firstItem as? NSView
            let secondView = constraint.secondItem as? NSView
            return firstView === overlay &&
                secondView === referenceView &&
                constraint.firstAttribute == attribute &&
                constraint.secondAttribute == attribute
        }
    }
}

@discardableResult
@MainActor
func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) -> Bool {
    guard let target = AppWindowChromeComposition()
        .contentOverlayTargetResolver
        .installationTarget(for: window) else { return false }

    let existingOverlay =
        (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView)
        ?? findFileDropOverlayView(in: target.container)

    if let existingOverlay {
        configureFileDropOverlay(existingOverlay, tabManager: tabManager)
        objc_setAssociatedObject(window, &fileDropOverlayKey, existingOverlay, .OBJC_ASSOCIATION_RETAIN)
        guard !fileDropOverlay(existingOverlay, isAttachedTo: target.reference, in: target.container) else {
            return true
        }
        existingOverlay.removeFromSuperview()
        attachFileDropOverlay(existingOverlay, to: target.reference, in: target.container)
        return true
    }

    let overlay = FileDropOverlayView(frame: target.reference.frame)
    configureFileDropOverlay(overlay, tabManager: tabManager)
    // Publish the overlay before mutating the view tree so any re-entrant lookup resolves
    // the in-flight view instead of installing a second overlay during layout.
    objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
    attachFileDropOverlay(overlay, to: target.reference, in: target.container)
    return true
}

@MainActor
private func installFileDropOverlayWhenReady(
    on window: NSWindow,
    tabManager: TabManager,
    remainingAttempts: Int = 16
) {
    guard !installFileDropOverlay(on: window, tabManager: tabManager),
          remainingAttempts > 0 else { return }

    // Defer retrying until the next main-loop turn so we don't mutate the
    // NSThemeFrame hierarchy while SwiftUI/AppKit is still attaching views.
    DispatchQueue.main.async { [weak window, weak tabManager] in
        guard let window, let tabManager else { return }
        installFileDropOverlayWhenReady(
            on: window,
            tabManager: tabManager,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

@MainActor
private final class SelectedWorkspaceDirectoryObserver: ObservableObject {
    private struct Snapshot: Equatable {
        let workspaceId: UUID?
        let currentDirectory: String?
        let remoteConfiguration: WorkspaceRemoteConfiguration?
        let remoteConnectionState: WorkspaceRemoteConnectionState?
        let remoteConnectionDetail: String?
        let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
    }

    @Published private(set) var directoryChangeGeneration: UInt64 = 0
    private weak var tabManager: TabManager?
    private var cancellable: AnyCancellable?

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancellable == nil else { return }
        self.tabManager = tabManager
        cancellable = tabManager.selectedTabIdPublisher
            .map { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .map { workspace -> AnyPublisher<Snapshot, Never> in
                guard let workspace else {
                    return Just(
                        Snapshot(
                            workspaceId: nil,
                            currentDirectory: nil,
                            remoteConfiguration: nil,
                            remoteConnectionState: nil,
                            remoteConnectionDetail: nil,
                            remoteDaemonStatus: nil
                        )
                    )
                    .eraseToAnyPublisher()
                }
                return workspace.$currentDirectory
                    .combineLatest(
                        workspace.$remoteConfiguration,
                        workspace.$remoteConnectionState,
                        workspace.$remoteConnectionDetail
                    )
                    .combineLatest(workspace.$remoteDaemonStatus)
                    .map { values, remoteDaemonStatus in
                        let (
                            currentDirectory,
                            remoteConfiguration,
                            remoteConnectionState,
                            remoteConnectionDetail
                        ) = values
                        return Snapshot(
                            workspaceId: workspace.id,
                            currentDirectory: currentDirectory,
                            remoteConfiguration: remoteConfiguration,
                            remoteConnectionState: remoteConnectionState,
                            remoteConnectionDetail: remoteConnectionDetail,
                            remoteDaemonStatus: remoteDaemonStatus
                        )
                    }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.directoryChangeGeneration &+= 1
            }
    }
}

struct ContentView: View {
    var updateViewModel: UpdateStateModel
    let windowId: UUID
    @EnvironmentObject var tabManager: TabManager
    // ContentView observes the coalesced unread projection, NOT the notification
    // store. Reading `notificationStore` directly here would re-render the entire
    // content view + sidebar on every notification publish (terminal/agent
    // activity), which reconstructs every workspace row and starves the main
    // thread (issue #2586 class; surfaced as scroll lag). `notificationStore`
    // stays available as an unobserved singleton for actions and pass-down.
    @EnvironmentObject var sidebarUnread: SidebarUnreadModel
    var notificationStore: TerminalNotificationStore { .shared }
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @EnvironmentObject var fileExplorerState: FileExplorerState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyleRawValue = TitlebarControlsStyle.classic.rawValue
    @AppStorage(RightSidebarWidthSettings.maxWidthKey) private var rightSidebarMaxWidthSetting = RightSidebarWidthSettings.noOverrideValue
    @AppStorage(SessionPersistencePolicy.sidebarMinimumWidthKey) private var sidebarMinimumWidthSetting = SessionPersistencePolicy.defaultMinimumSidebarWidth
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey) private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey) private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey) private var titlebarTrafficLightTabBarInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey) private var titlebarTrafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @State private var sidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
    @State private var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State private var isResizerDragging = false
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State private var observedWindow: NSWindow?
    @State private var sidebarRenderWorkerClient: RenderWorkerClient?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @StateObject private var fileExplorerStore = FileExplorerStore()
    @StateObject private var sessionIndexStore = SessionIndexStore()
    @StateObject private var selectedWorkspaceDirectoryObserver = SelectedWorkspaceDirectoryObserver()
    @State private var commandPaletteOverlayRenderModel = CommandPaletteOverlayRenderModel()
    @State private var backgroundWorkspacePrimeCoordinator = BackgroundWorkspacePrimeCoordinator()
    @State private var fileExplorerWidth: CGFloat = 220
    @State private var fileExplorerDragStartWidth: CGFloat?
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State private var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State private var sidebarResizerPointerMonitor: Any?
    @State private var isResizerBandActive = false
    @State private var isSidebarResizerCursorActive = false
    @State private var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @State private var isCommandPalettePresented = false
    @State private var commandPaletteQuery: String = ""
    @State private var commandPaletteMode: CommandPaletteMode = .commands
    @State private var commandPaletteRenameDraft: String = ""
    @State private var commandPaletteWorkspaceDescriptionDraft: String = ""
    @State private var commandPaletteWorkspaceDescriptionHeight: CGFloat = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    @State private var commandPaletteSelectedResultIndex: Int = 0
    @State private var commandPaletteSelectionAnchorCommandID: String?
    @State private var commandPaletteScrollTargetIndex: Int?
    @State private var commandPaletteScrollTargetAnchor: UnitPoint?
    @State private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @State private var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @State private var commandPaletteSearchCommandsByID: [String: CommandPaletteCommand] = [:]
    @State private var commandPaletteNucleoSearchIndex: CommandPaletteNucleoSearchIndex<String>?
    @State private var commandPaletteSearchIndexBuildTask: Task<Void, Never>?
    @State private var commandPaletteSearchIndexBuildGeneration: UInt64 = 0
    @State private var cachedCommandPaletteResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResultsVersion: UInt64 = 0
    @State private var commandPaletteVisibleResultsScope: CommandPaletteListScope?
    @State private var commandPaletteVisibleResultsFingerprint: Int?
    @State private var cachedCommandPaletteScope: CommandPaletteListScope?
    @State private var cachedCommandPaletteFingerprint: Int?
    @State private var cachedDefaultTerminalIsDefault = DefaultTerminalRegistration.currentStatus().isDefault
    @State private var commandPalettePendingDismissFocusTarget: CommandPaletteRestoreFocusTarget?
    @State private var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem?
    @State private var commandPalettePendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior?
    @State private var commandPaletteSearchTask: Task<Void, Never>?
    @State private var commandPaletteSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchScope: CommandPaletteListScope?
    @State private var commandPaletteResolvedSearchFingerprint: Int?
    @State private var commandPaletteResolvedMatchingQuery = ""
    @State private var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @State private var commandPaletteForkableAgentActivePanelKey: String?
    @State private var commandPaletteForkableAgentProbeIDsByPanelKey: [String: UUID] = [:]
    @State var commandPaletteForkableAgentSupportedPanelKeys: Set<String> = []
    @State var commandPaletteForkableAgentSnapshotsByPanelKey: [String: SessionRestorableAgentSnapshot] = [:]
    @State var commandPaletteForkableAgentSnapshotFingerprintsByPanelKey: [String: String] = [:]
    @State var commandPaletteForkableAgentRemoteContextsByPanelKey: [String: Bool] = [:]
    @State var commandPaletteForkableAgentResultHadFallbackByPanelKey: [String: Bool] = [:]
    @State private var commandPaletteForkableAgentAvailabilityTasksByPanelKey: [String: Task<Void, Never>] = [:]
    @State private var commandPaletteForkableAgentProbeFingerprintsByPanelKey: [String: String] = [:]
    @State private var isCommandPaletteSearchPending = false
    @State private var commandPalettePendingActivation: CommandPalettePendingActivation?
    @State private var commandPaletteResultsRevision: UInt64 = 0
    @State private var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] = [:]
    @State private var isFeedbackComposerPresented = false
    @AppStorage(AppCatalogSection().renameSelectsExistingName.userDefaultsKey)
    private var commandPaletteRenameSelectAllOnFocus = AppCatalogSection().renameSelectsExistingName.defaultValue
    @AppStorage(AppCatalogSection().commandPaletteSearchesAllSurfaces.userDefaultsKey)
    private var commandPaletteSearchAllSurfaces = AppCatalogSection().commandPaletteSearchesAllSurfaces.defaultValue
    @AppStorage(AppearanceSettings.appearanceModeKey) private var appearanceMode = AppearanceSettings.defaultMode.rawValue
    @State private var commandPaletteShouldFocusWorkspaceDescriptionEditor = false
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool
    private let windowChrome = AppWindowChromeComposition()

    private struct CommandPaletteRestoreFocusTarget {
        let workspaceId: UUID
        let panelId: UUID
        let intent: PanelFocusIntent
    }

    static func tmuxWorkspacePaneExactRect(
        for panel: Panel,
        in contentView: NSView
    ) -> CGRect? {
        let targetView: NSView?
        switch panel {
        case let terminal as TerminalPanel:
            targetView = terminal.hostedView
        case let browser as BrowserPanel:
            targetView = browser.webView
        default:
            targetView = nil
        }
        guard let targetView else { return nil }
        return tmuxWorkspacePaneExactRect(for: targetView, in: contentView)
    }

    static func tmuxWorkspacePaneExactRect(
        for targetView: NSView,
        in contentView: NSView
    ) -> CGRect? {
        guard let contentWindow = contentView.window,
              let targetWindow = targetView.window,
              contentWindow === targetWindow,
              targetView.superview != nil else {
            return nil
        }

        let rectInWindow = targetView.convert(targetView.bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard rectInContent.width > 1, rectInContent.height > 1 else { return nil }
        return rectInContent
    }

    static func preferredTmuxWorkspacePaneWindowOverlayRect(
        exactRect: CGRect?,
        paneRect: CGRect?
    ) -> CGRect? {
        guard let paneRect else { return exactRect }
        guard let exactRect,
              exactRect.width > 1,
              exactRect.height > 1 else {
            return paneRect
        }

        let tolerance: CGFloat = 0.5
        let exactFitsWithinPane =
            exactRect.minX >= paneRect.minX - tolerance &&
            exactRect.maxX <= paneRect.maxX + tolerance &&
            exactRect.minY >= paneRect.minY - tolerance &&
            exactRect.maxY <= paneRect.maxY + tolerance
        return exactFitsWithinPane ? exactRect : paneRect
    }

    private func tmuxWorkspacePaneWindowOverlayState(for window: NSWindow) -> TmuxWorkspacePaneOverlayRenderState? {
        guard TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay,
              let workspace = tabManager.selectedWorkspace else { return nil }
        let layoutSnapshot = WorkspaceContentView.effectiveTmuxLayoutSnapshot(
            cachedSnapshot: workspace.tmuxLayoutSnapshot,
            liveSnapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let contentView = window.contentView

        let unreadRects: [CGRect]
        let isWorkspaceManuallyUnread = sidebarUnread.hasManualUnread(forWorkspaceId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()
        if let layoutSnapshot, let contentView {
            unreadRects = layoutSnapshot.panes.compactMap { pane in
                guard let selectedTabId = pane.selectedTabId,
                      let tabUUID = UUID(uuidString: selectedTabId),
                      let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)),
                      let panel = workspace.panels[panelId] else {
                    return nil
                }

                let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: sidebarUnread.hasVisibleNotificationIndicator(
                        forWorkspaceId: workspace.id,
                        surfaceId: panelId
                    ),
                    hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                        workspace.restoredUnreadPanelIds.contains(panelId),
                    isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                    isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
                )
                guard shouldShowUnread else { return nil }

                let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                    layoutSnapshot: layoutSnapshot,
                    paneId: workspace.paneId(forPanelId: panelId)
                )
                let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
                return Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                    exactRect: exactRect,
                    paneRect: paneRect
                )
            }
        } else {
            unreadRects = WorkspaceContentView.tmuxWorkspacePaneWindowUnreadRects(
                workspace: workspace,
                notificationStore: notificationStore,
                layoutSnapshot: layoutSnapshot
            )
        }

        let flashRect: CGRect?
        if let panelId = workspace.tmuxWorkspaceFlashPanelId,
           let panel = workspace.panels[panelId],
           let contentView {
            let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.paneId(forPanelId: panelId)
            )
            let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
            flashRect = Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            )
        } else {
            flashRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.tmuxWorkspaceFlashPanelId.flatMap { workspace.paneId(forPanelId: $0) }
            )
        }

        if unreadRects.isEmpty, flashRect == nil {
            return TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspace.id,
                unreadRects: [],
                flashRect: nil,
                flashToken: workspace.tmuxWorkspaceFlashToken,
                flashReason: workspace.tmuxWorkspaceFlashReason
            )
        }

        return TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspace.id,
            unreadRects: unreadRects,
            flashRect: flashRect,
            flashToken: workspace.tmuxWorkspaceFlashToken,
            flashReason: workspace.tmuxWorkspaceFlashReason
        )
    }

    private struct CommandPaletteSwitcherWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let selectedWorkspaceId: UUID?
        let windowLabel: String?
    }

    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    private static let commandPaletteUsageDefaultsKey = "commandPalette.commandUsage.v1"
    nonisolated private static let commandPaletteCommandsPrefix = ">"
    private static let commandPaletteVisiblePreviewResultLimit = 48
    private static let commandPaletteVisiblePreviewCandidateLimit = 128
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0
    private static let minimumRightSidebarWidth: CGFloat = CGFloat(RightSidebarWidthSettings.minimumWidth)
    private static let maximumRightSidebarWidth: CGFloat = CGFloat(RightSidebarWidthSettings.builtInMaximumWidth)
    private static let minimumTerminalWidthWithRightSidebar: CGFloat = 360

    private var minimumSidebarWidth: CGFloat {
        CGFloat(SessionPersistencePolicy.sanitizedMinimumSidebarWidth(sidebarMinimumWidthSetting))
    }

    private enum SidebarResizerHandle: Hashable {
        case divider
        case explorerDivider
    }

    /// Returns the current drag width, start width capture, width update, and drag end cleanup for a resizer handle.
    private func resizerConfig(for handle: SidebarResizerHandle, availableWidth: CGFloat) -> (
        currentWidth: CGFloat,
        captureStart: () -> Void,
        updateWidth: (CGFloat) -> Void,
        finishDrag: () -> Void
    ) {
        switch handle {
        case .divider:
            return (
                currentWidth: sidebarWidth,
                captureStart: { sidebarDragStartWidth = sidebarWidth },
                updateWidth: { translation in
                    let startWidth = sidebarDragStartWidth ?? sidebarWidth
                    let nextWidth = Self.clampedSidebarWidth(
                        startWidth + translation,
                        maximumWidth: maxSidebarWidth(availableWidth: availableWidth),
                        minimumWidth: minimumSidebarWidth
                    )
                    withTransaction(Transaction(animation: nil)) {
                        sidebarWidth = nextWidth
                    }
                },
                finishDrag: { sidebarDragStartWidth = nil }
            )
        case .explorerDivider:
            return (
                currentWidth: fileExplorerWidth,
                captureStart: { fileExplorerDragStartWidth = fileExplorerWidth },
                updateWidth: { translation in
                    let startWidth = fileExplorerDragStartWidth ?? fileExplorerWidth
                    let nextWidth = Self.clampedRightSidebarWidth(
                        startWidth - translation,
                        availableWidth: availableWidth,
                        configuredMaximumWidth: rightSidebarConfiguredMaximumWidth
                    )
                    withTransaction(Transaction(animation: nil)) {
                        fileExplorerWidth = nextWidth
                    }
                },
                finishDrag: {
                    fileExplorerDragStartWidth = nil
                    fileExplorerState.width = fileExplorerWidth
                }
            )
        }
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return max(minimumSidebarWidth, resolvedAvailableWidth * Self.maximumSidebarWidthRatio)
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1920
        return max(minimumSidebarWidth, fallbackScreenWidth * Self.maximumSidebarWidthRatio)
    }

    static func clampedSidebarWidth(
        _ candidate: CGFloat,
        maximumWidth: CGFloat,
        minimumWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultMinimumSidebarWidth)
    ) -> CGFloat {
        let sanitizedMaximumWidth = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return max(
                minimumWidth,
                min(sanitizedMaximumWidth, CGFloat(SessionPersistencePolicy.defaultSidebarWidth))
            )
        }
        return max(minimumWidth, min(sanitizedMaximumWidth, candidate))
    }

    static func clampedRightSidebarWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        configuredMaximumWidth: CGFloat? = nil
    ) -> CGFloat {
        let minimumWidth = Self.minimumRightSidebarWidth
        let sanitizedCandidate = candidate.isFinite ? candidate : 220
        let sanitizedAvailableWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 1920
        let availableWidthCap = max(
            minimumWidth,
            sanitizedAvailableWidth - Self.minimumTerminalWidthWithRightSidebar
        )
        let configuredOrDefaultCap: CGFloat
        if let configuredMaximumWidth, configuredMaximumWidth.isFinite {
            configuredOrDefaultCap = max(minimumWidth, configuredMaximumWidth)
        } else {
            configuredOrDefaultCap = Self.maximumRightSidebarWidth
        }
        let maximumWidth = min(configuredOrDefaultCap, availableWidthCap)
        return max(minimumWidth, min(maximumWidth, sanitizedCandidate))
    }

    private func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = Self.clampedSidebarWidth(
            sidebarWidth,
            maximumWidth: maxSidebarWidth(availableWidth: availableWidth),
            minimumWidth: minimumSidebarWidth
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    private func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        Self.clampedSidebarWidth(
            candidate,
            maximumWidth: maxSidebarWidth(),
            minimumWidth: minimumSidebarWidth
        )
    }

    private func resolvedRightSidebarAvailableWidth(_ availableWidth: CGFloat? = nil) -> CGFloat {
        if let availableWidth {
            return availableWidth
        }
        if let width = observedWindow?.contentView?.bounds.width {
            return width
        }
        if let width = observedWindow?.contentLayoutRect.width {
            return width
        }
        if let width = NSApp.keyWindow?.contentView?.bounds.width {
            return width
        }
        if let width = NSApp.keyWindow?.contentLayoutRect.width {
            return width
        }
        if let width = NSApp.keyWindow?.screen?.frame.width {
            return width
        }
        if let width = NSScreen.main?.frame.width {
            return width
        }
        return 1920
    }

    private var rightSidebarConfiguredMaximumWidth: CGFloat? {
        guard let width = RightSidebarWidthSettings().configuredMaximumWidth(from: rightSidebarMaxWidthSetting) else {
            return nil
        }
        return CGFloat(width)
    }

    private func normalizedRightSidebarWidth(_ candidate: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        Self.clampedRightSidebarWidth(
            candidate,
            availableWidth: resolvedRightSidebarAvailableWidth(availableWidth),
            configuredMaximumWidth: rightSidebarConfiguredMaximumWidth
        )
    }

    private func clampRightSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = normalizedRightSidebarWidth(fileExplorerWidth, availableWidth: availableWidth)
        guard abs(nextWidth - fileExplorerWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            fileExplorerWidth = nextWidth
        }
        fileExplorerState.width = nextWidth
    }

    private func activateSidebarResizerCursor() {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        sidebarResizerCursorReleaseWorkItem = nil
        isSidebarResizerCursorActive = true
        Self.fixedSidebarResizeCursor.set()
    }

    private func releaseSidebarResizerCursorIfNeeded(force: Bool = false) {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let shouldKeepCursor = !force
            && (isResizerDragging || isResizerBandActive || !hoveredResizerHandles.isEmpty || isLeftMouseButtonDown)
        guard !shouldKeepCursor else { return }
        guard isSidebarResizerCursorActive else { return }
        isSidebarResizerCursorActive = false
        NSCursor.arrow.set()
    }

    private func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: TimeInterval = 0) {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            sidebarResizerCursorReleaseWorkItem = nil
            releaseSidebarResizerCursorIfNeeded(force: force)
        }
        sidebarResizerCursorReleaseWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func dividerBandContains(pointInContent point: NSPoint, contentBounds: NSRect) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if sidebarState.isVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: sidebarWidth).contains(point.x) {
            return true
        }

        let rightDividerX = contentBounds.maxX - rightSidebarWidth
        return rightSidebarVisible &&
            SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightDividerX).contains(point.x)
    }

    private func updateSidebarResizerBandState(using _: NSEvent? = nil) {
        guard sidebarState.isVisible || rightSidebarVisible,
              let window = observedWindow,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live global pointer location instead of per-event coordinates.
        // Overlapping tracking areas (notably WKWebView) can deliver stale/jittery
        // event locations during cursor updates, which causes visible cursor flicker.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = dividerBandContains(pointInContent: pointInContent, contentBounds: contentView.bounds)
        isResizerBandActive = isInDividerBand

        if isInDividerBand || isResizerDragging {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // AppKit cursorUpdate handlers from overlapped portal/web views can run
            // after our local monitor callback and temporarily reset the cursor.
            // Re-assert on the next runloop turn to keep the resize cursor stable.
            DispatchQueue.main.async {
                Self.fixedSidebarResizeCursor.set()
            }
        } else {
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func startSidebarResizerCursorStabilizer() {
        guard sidebarResizerCursorStabilizer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler {
            updateSidebarResizerBandState()
            if isResizerBandActive || isResizerDragging {
                Self.fixedSidebarResizeCursor.set()
            } else {
                stopSidebarResizerCursorStabilizer()
            }
        }
        sidebarResizerCursorStabilizer = timer
        timer.resume()
    }

    private func stopSidebarResizerCursorStabilizer() {
        sidebarResizerCursorStabilizer?.cancel()
        sidebarResizerCursorStabilizer = nil
    }

    private func installSidebarResizerPointerMonitorIfNeeded() {
        guard sidebarResizerPointerMonitor == nil else { return }
        observedWindow?.acceptsMouseMovedEvents = true
        sidebarResizerPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
            ]
        ) { event in
            updateSidebarResizerBandState(using: event)
            let shouldOverrideCursorEvent: Bool = {
                switch event.type {
                case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined:
                    return true
                default:
                    return false
                }
            }()
            if shouldOverrideCursorEvent, (isResizerBandActive || isResizerDragging) {
                // Consume hover motion in divider band so overlapped views cannot
                // continuously reassert their own cursor while we are resizing.
                activateSidebarResizerCursor()
                Self.fixedSidebarResizeCursor.set()
                return nil
            }
            return event
        }
        updateSidebarResizerBandState()
    }

    private func removeSidebarResizerPointerMonitor() {
        if let monitor = sidebarResizerPointerMonitor {
            NSEvent.removeMonitor(monitor)
            sidebarResizerPointerMonitor = nil
        }
        isResizerBandActive = false
        isSidebarResizerCursorActive = false
        stopSidebarResizerCursorStabilizer()
        scheduleSidebarResizerCursorRelease(force: true)
    }

    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredResizerHandles.insert(handle)
                    activateSidebarResizerCursor()
                } else {
                    hoveredResizerHandles.remove(handle)
                    let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if isLeftMouseButtonDown {
                        // Keep resize cursor pinned through mouse-down so AppKit
                        // cursorUpdate events from overlapping views do not flash arrow.
                        activateSidebarResizerCursor()
                    } else {
                        // Give mouse-down + drag-start callbacks time to establish state
                        // before any cursor pop is attempted.
                        scheduleSidebarResizerCursorRelease(delay: 0.05)
                    }
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                hoveredResizerHandles.remove(handle)
                if isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    isResizerDragging = false
                }
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let config = resizerConfig(for: handle, availableWidth: availableWidth)
                        if !isResizerDragging {
                            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
                            isResizerDragging = true
                            config.captureStart()
                        }
                        activateSidebarResizerCursor()
                        config.updateWidth(value.translation.width)
                    }
                    .onEnded { _ in
                        if isResizerDragging {
                            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                            isResizerDragging = false
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            config.finishDrag()
                        }
                        activateSidebarResizerCursor()
                        scheduleSidebarResizerCursorRelease()
                    }
            )
            .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
    }

    private func placedSidebarResizerOverlay(
        handle: SidebarResizerHandle,
        edge: SidebarResizeInteraction.Edge,
        accessibilityIdentifier: String,
        dividerX: @escaping (CGFloat) -> CGFloat
    ) -> some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let resolvedDividerX = min(max(dividerX(totalWidth), 0), totalWidth)
            let leadingWidth = max(0, edge.handleX(dividerX: resolvedDividerX))

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    handle,
                    width: SidebarResizeInteraction.totalHitWidth,
                    availableWidth: totalWidth,
                    accessibilityIdentifier: accessibilityIdentifier
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
        }
    }

    private var sidebarResizerOverlay: some View {
        placedSidebarResizerOverlay(
            handle: .divider,
            edge: .leading,
            accessibilityIdentifier: "SidebarResizer",
            dividerX: { totalWidth in min(max(sidebarWidth, 0), totalWidth) }
        )
    }

    private var rightSidebarResizerOverlay: some View {
        placedSidebarResizerOverlay(
            handle: .explorerDivider,
            edge: .trailing,
            accessibilityIdentifier: "RightSidebarResizer",
            dividerX: { totalWidth in totalWidth - rightSidebarWidth }
        )
    }

    private var sidebarView: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            fileExplorerState: fileExplorerState,
            windowId: windowId,
            onSendFeedback: presentFeedbackComposer,
            onToggleSidebar: { sidebarState.toggle() },
            onNewTab: {
                AppDelegate.shared?.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.hiddenNewWorkspace"
                )
            },
            observedWindow: observedWindow,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds, lastSidebarSelectionIndex: $lastSidebarSelectionIndex, sidebarRenderWorkerClient: $sidebarRenderWorkerClient
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// Native titlebar inset reported by AppKit. Standard mode follows cmux's visual chrome;
    /// minimal WindowGroup hosts can still need the reported safe area cancelled.
    @State private var titlebarPadding: CGFloat = WindowChromeMetrics.defaultTitlebarHeight
    /// SwiftUI WindowGroup windows can still report a titlebar safe area; manually created
    /// main windows use MainWindowHostingView and report zero.
    @State private var hostingSafeAreaTop: CGFloat = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        Self.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        )
    }

    static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        guard isMinimalMode else { return WindowChromeMetrics.appTitlebarHeight }
        guard !isFullScreen else { return 0 }
        return -max(0, min(titlebarPadding, hostingSafeAreaTop))
    }

    nonisolated static func customTitlebarLeadingPadding(
        isFullScreen: Bool,
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        titlebarLeadingInset: CGFloat
    ) -> CGFloat {
        if isFullScreen && !isSidebarVisible {
            return 8
        }

        let minimumSidebarTitleInset = max(titlebarLeadingInset, minimumSidebarWidth + 12)
        guard isSidebarVisible else {
            return minimumSidebarTitleInset
        }

        let visibleSidebarTitleInset = sidebarWidth + 12
        // Absorb floating-point drift around the minimum-width clamp.
        guard sidebarWidth > minimumSidebarWidth + 0.5 else {
            return minimumSidebarTitleInset
        }
        return max(titlebarLeadingInset, visibleSidebarTitleInset)
    }

    /// Where the always-visible fullscreen titlebar controls (sidebar toggle,
    /// history, new tab, notifications) are anchored inside the titlebar band.
    struct FullscreenControlsPlacement: Equatable {
        var leadingPadding: CGFloat
        var topPadding: CGFloat
    }

    /// Resolves the placement for the fullscreen titlebar controls, or `nil` when
    /// they should not be shown. The controls are mounted in a single overlay
    /// anchor driven by this function so their on-screen position never depends on
    /// sidebar visibility; toggling the sidebar must not shift the accessory bar.
    nonisolated static func fullscreenControlsPlacement(
        isFullScreen: Bool,
        isSidebarVisible: Bool
    ) -> FullscreenControlsPlacement? {
        guard isFullScreen else { return nil }
        // Placement is intentionally independent of sidebar visibility so toggling
        // the sidebar in fullscreen never shifts the accessory bar. `topPadding`
        // mirrors the title row's top inset (see `customTitlebar`) so the controls'
        // center lines up with the folder icon / title.
        return FullscreenControlsPlacement(leadingPadding: 10, topPadding: 2)
    }

    private func terminalContent(appearance: WindowAppearanceSnapshot) -> some View {
        let mountedWorkspaceIdSet = Set(mountedWorkspaceIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = tabManager.selectedTabId
        let retiringWorkspaceId = self.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    let isRetiringWorkspace = retiringWorkspaceId == tab.id
                    let presentation = MountedWorkspacePresentation.resolve(
                        isSelectedWorkspace: isSelectedWorkspace,
                        isRetiringWorkspace: isRetiringWorkspace
                    )
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: presentation.isPanelVisible,
                        isWorkspaceInputActive: isInputActive,
                        rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus,
                        isFullScreen: isFullScreen,
                        workspacePortalPriority: portalPriority,
                        windowAppearance: appearance,
                        onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                            scheduleTitlebarThemeRefreshFromWorkspace(
                                workspaceId: tab.id,
                                reason: reason,
                                backgroundEventId: eventId,
                                backgroundSource: source,
                                notificationPayloadHex: payloadHex
                            )
                        }
                    )
                    .opacity(presentation.renderOpacity)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!presentation.isRenderedVisible)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
                .accessibilityHidden(sidebarSelectionState.selection != .notifications)
        }
        .padding(.top, effectiveTitlebarPadding)
    }

    private func terminalContentWithSidebarDropOverlay(appearance: WindowAppearanceSnapshot) -> some View {
        terminalContent(appearance: appearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .overlay {
                SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
            }
    }

    private func terminalContentWithRightSidebarPanel(appearance: WindowAppearanceSnapshot) -> some View {
        // The right-sidebar shell remains in the view tree so its frame can
        // animate without SwiftUI insertion/removal. Cold hidden launches defer
        // heavy mode content until the sidebar has been shown at least once.
        return HStack(spacing: 0) {
            terminalContentWithSidebarDropOverlay(appearance: appearance)
            rightSidebarPanelWithBackdrop(appearance: appearance)
        }
    }

    private var rightSidebarVisible: Bool {
        fileExplorerState.isVisible
    }

    private var rightSidebarWidth: CGFloat {
        rightSidebarVisible ? fileExplorerWidth : 0
    }

    private func sidebarBackdropLayer(
        width: CGFloat,
        role: WindowBackdropRole,
        appearance: WindowAppearanceSnapshot
    ) -> some View {
        WindowBackdropLayer(role: role, snapshot: appearance)
            .ignoresSafeArea()
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: appearance.sidebarSettings.materialPolicy.cornerRadius, style: .continuous))
            .clipped()
            .allowsHitTesting(false)
    }

    private func sidebarPanelContainer<Content: View>(
        width: CGFloat,
        alignment: Alignment,
        role: WindowBackdropRole,
        appearance: WindowAppearanceSnapshot,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            sidebarBackdropLayer(width: width, role: role, appearance: appearance)
            content()
                .environment(\.colorScheme, appearance.sidebarContentColorScheme)
        }
        .frame(width: width)
    }

    private func sidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        sidebarPanelContainer(width: sidebarWidth, alignment: .leading, role: .leftSidebar, appearance: appearance) {
            sidebarView
        }
    }

    private func rightSidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        let panel = sidebarPanelContainer(width: rightSidebarWidth, alignment: .trailing, role: .rightSidebar, appearance: appearance) {
            rightSidebarPanel(appearance: appearance)
        }
        .overlay(alignment: .leading) {
            if rightSidebarVisible {
                WindowChromeBorder(
                    orientation: .vertical,
                    refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                    backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
                )
            }
        }

        return panel
    }

    private func rightSidebarPanel(appearance: WindowAppearanceSnapshot) -> some View {
        return RightSidebarPanelView(
            tabManager: tabManager,
            fileExplorerStore: fileExplorerStore,
            fileExplorerState: fileExplorerState,
            sessionIndexStore: sessionIndexStore,
            titlebarHeight: RightSidebarChromeMetrics.titlebarHeight,
            windowAppearance: appearance,
            workspaceId: tabManager.selectedTabId,
            onResumeSession: { entry in
                resumeSession(entry: entry)
            },
            onOpenFilePreview: { filePath in
                openFilePreviewFromSidebar(filePath: filePath)
            },
            onOpenAsPane: { mode in
                openRightSidebarToolPane(mode)
            },
            onClose: {
                #if DEBUG
                cmuxDebugLog("rightSidebar.closeButton")
                #endif
                _ = AppDelegate.shared?.closeRightSidebarInActiveMainWindow(preferredWindow: observedWindow)
            }
        )
        .frame(width: rightSidebarWidth)
        .clipped()
        .allowsHitTesting(rightSidebarVisible)
        .accessibilityHidden(!rightSidebarVisible)
        .transaction { $0.animation = nil }
        .onAppear {
            let sanitized = normalizedRightSidebarWidth(fileExplorerState.width)
            fileExplorerWidth = sanitized
            if abs(fileExplorerState.width - sanitized) > 0.5 {
                DispatchQueue.main.async {
                    fileExplorerState.width = sanitized
                }
            }
        }
        .onChange(of: fileExplorerState.width) { newValue in
            if fileExplorerDragStartWidth == nil {
                let sanitized = normalizedRightSidebarWidth(newValue)
                if abs(newValue - sanitized) > 0.5 {
                    DispatchQueue.main.async {
                        fileExplorerState.width = sanitized
                    }
                    return
                }
                fileExplorerWidth = sanitized
            }
        }
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults().opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults().hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarState") private var sidebarStateSetting = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false
    @State private var titlebarLeadingInset: CGFloat = 12
    private var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    private var windowAppearanceSnapshot: WindowAppearanceSnapshot {
        _ = titlebarThemeGeneration
        return windowChrome.appearanceSnapshot(
            settings: WindowAppearanceUserSettingsSnapshot(
                unifySurfaceBackdrops: sidebarMatchTerminalBackground,
                colorScheme: AppearanceSettings.colorScheme(for: appearanceMode, fallback: colorScheme),
                sidebarMaterial: sidebarMaterial,
                sidebarBlendMode: sidebarBlendMode,
                sidebarState: sidebarStateSetting,
                sidebarTintHex: sidebarTintHex,
                sidebarTintHexLight: sidebarTintHexLight,
                sidebarTintHexDark: sidebarTintHexDark,
                sidebarTintOpacity: sidebarTintOpacity,
                sidebarCornerRadius: sidebarCornerRadius,
                sidebarBlurOpacity: sidebarBlurOpacity,
                bgGlassEnabled: bgGlassEnabled,
                bgGlassTintHex: bgGlassTintHex,
                bgGlassTintOpacity: bgGlassTintOpacity
            )
        )
    }

    private func fakeTitlebarTextColor(appearance: WindowAppearanceSnapshot) -> Color {
        let ghosttyBackground = appearance.terminalBackgroundColor
        return ghosttyBackground.isLightColor
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: TerminalNotificationStore.shared,
            viewModel: fullscreenControlsViewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: {
                AppDelegate.shared?.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.fullscreenNewWorkspace"
                )
            },
            onFocusHistoryBack: {
                if !tabManager.navigateBack() {
                    NSSound.beep()
                }
            },
            onFocusHistoryForward: {
                if !tabManager.navigateForward() {
                    NSSound.beep()
                }
            },
            visibilityMode: .alwaysVisible
        )
        .offset(y: -TitlebarControlsVisualMetrics.verticalLift)
    }

    /// Intrinsic width of ``fullscreenControls`` for the current controls style.
    /// Used to reserve space in the title row so the title flows to the right of
    /// the controls, which are themselves mounted once in the band overlay.
    private var fullscreenControlsWidth: CGFloat {
        let style = TitlebarControlsStyle(rawValue: titlebarControlsStyleRawValue) ?? .classic
        return TitlebarControlsLayoutMetrics.contentSize(config: style.config).width
    }

    private var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarTrafficLightTabBarInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarTrafficLightTitlebarLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            )
        )
    }

    private func customTitlebar(appearance: WindowAppearanceSnapshot) -> some View {
        let titlebarContentHeight = max(1, WindowChromeMetrics.appTitlebarHeight - 2)
        let leadingPadding = Self.customTitlebarLeadingPadding(
            isFullScreen: isFullScreen,
            isSidebarVisible: sidebarState.isVisible,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            titlebarLeadingInset: titlebarLeadingInset
        )
        return ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(
                inset: $titlebarLeadingInset,
                baseLeadingInset: { MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInset() }
            )
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                if isFullScreen && !sidebarState.isVisible {
                    // Reserve the controls' width so the title flows to their right.
                    // The visible controls are rendered once in the band overlay (see
                    // `workspaceTitlebarBand`) so their position never depends on
                    // sidebar visibility.
                    Color.clear
                        .frame(width: fullscreenControlsWidth, height: titlebarContentHeight)
                        .allowsHitTesting(false)
                }

                // Draggable folder icon + focused command name
                if let directory = focusedDirectory {
                    DetachedFolderDragIcon(directory: directory)
                        .frame(width: 16, height: 16)
                        .padding(.leading, -6)
                }

                Text(titlebarText)
                    .cmuxFont(size: 13, weight: .bold)
                    .foregroundColor(fakeTitlebarTextColor(appearance: appearance))
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer()

            }
            .frame(height: titlebarContentHeight)
            .padding(.top, 2)
            .padding(.leading, leadingPadding)
            .padding(.trailing, 8)
        }
        .frame(height: WindowChromeMetrics.appTitlebarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(TitlebarDoubleClickMonitorView())
        .overlay(alignment: .bottom) {
            WindowChromeBorder(
                orientation: .horizontal,
                refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
            )
                .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
        }
    }

    private func workspaceTitlebarBand(appearance: WindowAppearanceSnapshot) -> some View {
        Color.clear
            .frame(height: WindowChromeMetrics.appTitlebarHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                customTitlebar(appearance: appearance)
                    // The workspace titlebar band spans the full window width and sits at
                    // zIndex(100) over the content/sidebar layout. Its drag/double-click
                    // surface (`WindowDragHandleView` + `.contentShape(Rectangle())`) must
                    // not cover the right sidebar, whose mode bar (Files/Search/Feed/Vault)
                    // lives inside the titlebar-height strip — otherwise the band wins the
                    // hit-test and swallows every click/hover on those buttons (#5099).
                    // Confine the interactive titlebar surface to the area left of the
                    // right sidebar, matching the pre-#5017 "only over terminal content,
                    // not the sidebar" intent. The left sidebar's titlebar controls live in
                    // the AppKit titlebar accessory (above this band), so only the trailing
                    // (right-sidebar) edge needs to be ceded here.
                    //
                    // `rightSidebarWidth` is already `rightSidebarVisible ? fileExplorerWidth : 0`,
                    // so it collapses to 0 when the sidebar is hidden. The sidebar panel itself
                    // snaps without animation (`.transaction { $0.animation = nil }`), so we match
                    // that here — otherwise this inset could animate out of step with the panel on
                    // toggle and momentarily expose (or re-cover) the mode bar mid-transition.
                    .padding(.trailing, rightSidebarWidth)
                    .animation(nil, value: rightSidebarWidth)
            }
            .overlay(alignment: .topLeading) {
                if let placement = Self.fullscreenControlsPlacement(
                    isFullScreen: isFullScreen,
                    isSidebarVisible: sidebarState.isVisible
                ) {
                    fullscreenControls
                        .environment(
                            \.colorScheme,
                            sidebarState.isVisible
                                ? appearance.sidebarContentColorScheme
                                : appearance.chromeColorScheme
                        )
                        // Same vertical frame as the title row (`customTitlebar`)
                        // so the controls' center matches the folder icon / title.
                        .frame(height: max(1, WindowChromeMetrics.appTitlebarHeight - 2), alignment: .center)
                        .padding(.top, placement.topPadding)
                        .padding(.leading, placement.leadingPadding)
                }
            }
    }

    private func syncTrafficLightInset() {
        let inset: CGFloat = (isMinimalMode && !sidebarState.isVisible && !isFullScreen)
            ? CGFloat(titlebarDebugChromeSnapshot.trafficLightTabBarLeadingInset)
            : 0
        tabManager.syncWorkspaceTabBarLeadingInset(inset)
    }

    private func applyTitlebarDebugChromeChange() {
        if let observedWindow {
            AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
        }
        syncTrafficLightInset()
    }

    private func schedulePortalGeometrySynchronize() {
        if let observedWindow {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
        } else {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        }
    }

    private func refreshWindowChromeMetrics(for window: NSWindow) {
        // Keep native measurements around for minimal WindowGroup safe-area cancellation.
        // Standard mode uses cmux's visual chrome height for layout.
        let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let nextPadding = WindowChromeMetrics.clampedTitlebarHeight(computedTitlebarHeight)
        let nextSafeAreaTop = max(0, window.contentView?.safeAreaInsets.top ?? 0)
        if abs(titlebarPadding - nextPadding) > 0.5 {
            DispatchQueue.main.async {
                titlebarPadding = nextPadding
            }
        }
        if abs(hostingSafeAreaTop - nextSafeAreaTop) > 0.5 {
            DispatchQueue.main.async {
                hostingSafeAreaTop = nextSafeAreaTop
            }
        }
    }

    @MainActor private func updateTitlebarText() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        let title = tabManager.resolvedWorkspaceDisplayTitle(for: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
    }

    @MainActor private func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    private func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        if GhosttyApp.shared.backgroundLogEnabled {
            let eventLabel = backgroundEventId.map(String.init) ?? "nil"
            let sourceLabel = backgroundSource ?? "nil"
            let payloadLabel = notificationPayloadHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        }
    }

    private func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard tabManager.selectedTabId == workspaceId else {
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(tabManager.selectedTabId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    private func resumeSession(entry: SessionEntry) {
        SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
    }

    func openRightSidebarToolPane(_ mode: RightSidebarMode) {
        guard mode.canOpenAsPane,
              let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }

        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        _ = workspace.openOrFocusRightSidebarToolSurface(inPane: paneId, mode: mode, focus: true)
    }

    private func openFilePreviewFromSidebar(filePath: String) {
        guard let workspace = tabManager.selectedWorkspace else { return }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }

        sidebarSelectionState.selection = .tabs
        if workspace.isRemoteWorkspace {
            Task { [weak workspace, fileExplorerStore] in
                guard let workspace else { return }
                do {
                    let localURL = try await fileExplorerStore.materializeRemoteFileForPreview(path: filePath)
                    _ = workspace.openFileSurfaces(
                        inPane: paneId,
                        filePaths: [localURL.path],
                        focus: true,
                        reuseExisting: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        _ = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        )
    }

    private func syncFileExplorerDirectory() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            // No selection means we have no local cwd to scope by; clear so the
            // sessions panel doesn't keep filtering by a stale previous tab.
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }

        fileExplorerStore.showHiddenFiles = true

        if tab.isRemoteWorkspace {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            guard shouldSyncFileExplorerStore else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            guard let config = tab.remoteConfiguration, config.transport == .ssh else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            let unavailableDetail = tab.remoteConnectionDetail ?? tab.remoteDaemonStatus.detail

            #if DEBUG
            let hasUnavailableDetail = unavailableDetail?.isEmpty == false
            cmuxDebugLog(
                "fileExplorer.sync remote state=\(tab.remoteConnectionState.rawValue) " +
                "hasDestination=\(config.destination.isEmpty ? 0 : 1) " +
                "hasDisplayTarget=\(config.displayTarget.isEmpty ? 0 : 1) " +
                "hasIdentityFile=\(config.identityFile == nil ? 0 : 1) " +
                "hasDetail=\(hasUnavailableDetail ? 1 : 0)"
            )
            #endif

            fileExplorerStore.applyWorkspaceRoot(
                .remoteSSH(
                    workspaceId: tab.id,
                    connection: SSHFileExplorerConnection(
                        destination: config.destination,
                        port: config.port,
                        identityFile: config.identityFile,
                        sshOptions: config.sshOptions
                    ),
                    displayTarget: config.displayTarget,
                    rootPath: tab.currentDirectory,
                    isAvailable: tab.remoteConnectionState == .connected,
                    unavailableDetail: unavailableDetail
                )
            )
            return
        }

        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }

        sessionIndexStore.setCurrentDirectoryIfChanged(dir)
        guard shouldSyncFileExplorerStore else {
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }
        fileExplorerStore.applyWorkspaceRoot(.local(workspaceId: tab.id, path: dir))
    }

    private var shouldSyncFileExplorerStore: Bool {
        FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
            isRightSidebarVisible: fileExplorerState.isVisible,
            mode: fileExplorerState.mode
        )
    }

    private var focusedDirectory: String? {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return nil
        }
        // Use focused panel's directory if available
        if let focusedPanelId = tab.focusedPanelId,
           let panelDir = tab.panelDirectories[focusedPanelId] {
            let trimmed = panelDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private func contentAndSidebarLayout(appearance: WindowAppearanceSnapshot) -> AnyView {
        let layout: AnyView
        // When matching terminal background, use HStack so both sidebar and terminal
        // sit directly on the window background with no intermediate layers.
        let useWithinWindow = sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue
            && !sidebarMatchTerminalBackground
        if useWithinWindow {
            // Overlay mode keeps the left sidebar on top, but the right
            // sidebar stays in an HStack so terminal rows are clipped before
            // the sidebar backdrop samples the window.
            layout = AnyView(
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        terminalContentWithSidebarDropOverlay(appearance: appearance)
                            .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        rightSidebarPanelWithBackdrop(appearance: appearance)
                    }
                    if sidebarState.isVisible {
                        sidebarPanelWithBackdrop(appearance: appearance)
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarPanelWithBackdrop(appearance: appearance)
                    }
                    terminalContentWithRightSidebarPanel(appearance: appearance)
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
                .overlay(alignment: .leading) {
                    if rightSidebarVisible {
                        rightSidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

    var body: some View {
        let appearance = windowAppearanceSnapshot
        var view = AnyView(
            ZStack(alignment: .topLeading) {
                WindowBackdropLayer(role: .windowRoot, snapshot: appearance)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                contentAndSidebarLayout(appearance: appearance)

                if !isMinimalMode {
                    workspaceTitlebarBand(appearance: appearance)
                        .zIndex(100)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)
                .background(
                    MinimalModeTitlebarEventSurfaceView(isEnabled: isMinimalMode && !isFullScreen)
                )
        )

        view = AnyView(view.onAppear {
            selectedWorkspaceDirectoryObserver.wire(tabManager: tabManager)
            tabManager.applyWindowBackgroundForSelectedTab()
            reconcileMountedWorkspaceIds()
            previousSelectedWorkspaceId = tabManager.selectedTabId
            installSidebarResizerPointerMonitorIfNeeded()
            let restoredWidth = normalizedSidebarWidth(sidebarState.persistedWidth)
            if abs(sidebarWidth - restoredWidth) > 0.5 {
                sidebarWidth = restoredWidth
            }
            if abs(sidebarState.persistedWidth - restoredWidth) > 0.5 {
                sidebarState.persistedWidth = restoredWidth
            }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)
            updateTitlebarText()
            syncTrafficLightInset()

            // Startup recovery (#399): if session restore or a race condition leaves the
            // view in a broken state (empty tabs, no selection, unmounted workspaces),
            // detect and recover after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tabManager] in
                guard let tabManager else { return }
                var didRecover = false

                // Ensure there is at least one workspace.
                if tabManager.tabs.isEmpty {
                    tabManager.addWorkspace()
                    didRecover = true
                }

                // Ensure selectedTabId points to an existing workspace.
                if tabManager.selectedTabId == nil || !tabManager.tabs.contains(where: { $0.id == tabManager.selectedTabId }) {
                    tabManager.selectedTabId = tabManager.tabs.first?.id
                    didRecover = true
                }

                // Ensure mountedWorkspaceIds is populated.
                if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in tabManager.tabs.contains { $0.id == id } }) {
                    reconcileMountedWorkspaceIds()
                    didRecover = true
                }

                // Ensure sidebar selection is valid.
                if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                    didRecover = true
                }

                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)

                if didRecover {
#if DEBUG
                    cmuxDebugLog("startup.recovery tabCount=\(tabManager.tabs.count) selected=\(tabManager.selectedTabId?.uuidString.prefix(8) ?? "nil") mounted=\(mountedWorkspaceIds.count)")
#endif
                    sentryBreadcrumb("startup.recovery", data: [
                        "tabCount": tabManager.tabs.count,
                        "selectedTabId": tabManager.selectedTabId?.uuidString ?? "nil",
                        "mountedCount": mountedWorkspaceIds.count
                    ])
                }
            }
        })

        view = AnyView(view.onChange(of: tabManager.selectedTabId) { newValue in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                )
            } else {
                cmuxDebugLog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
            }
#endif
            tabManager.applyWindowBackgroundForSelectedTab()
            startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
            reconcileMountedWorkspaceIds(selectedId: newValue)
            AppDelegate.shared?.syncBonsplitTabShortcutHintEligibility(in: observedWindow)
            guard let newValue else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [newValue]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
            }
            updateTitlebarText()
        })

        view = AnyView(view.onChange(of: showModifierHoldHints) { _, _ in
            AppDelegate.shared?.syncBonsplitTabShortcutHintEligibility(in: observedWindow)
        })

        view = AnyView(view.onChange(of: selectedTabIds) { _ in
            syncSidebarSelectedWorkspaceIds()
        })

        // File explorer: keep the Combine subscription stable across body re-evaluations.
        view = AnyView(view.onChange(of: selectedWorkspaceDirectoryObserver.directoryChangeGeneration) { _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: tabManager.isWorkspaceCycleHot) { _ in
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
                )
            } else {
                cmuxDebugLog("ws.view.hotChange id=none hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)")
            }
#endif
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onChange(of: retiringWorkspaceId) { _ in
            reconcileMountedWorkspaceIds()
        })

        // Prime background workspaces off-screen. Rendering them just to run a task
        // mounts every keepAllAlive tab view and can materialize hidden terminals.
        view = AnyView(view.task(id: backgroundWorkspacePrimeCoordinator.taskKey(for: tabManager)) {
            await backgroundWorkspacePrimeCoordinator.primePendingBackgroundWorkspaces(tabManager: tabManager)
        })

        view = AnyView(view.onReceive(tabManager.$debugPinnedWorkspaceLoadIds) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(tabManager.$mountedBackgroundWorkspaceLoadIds) { _ in
            reconcileMountedWorkspaceIds()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
            guard tabManager.shouldScheduleRawTitleRefresh(forWorkspaceId: GhosttyTitleChange(notification: notification)?.tabId) else { return }
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspaceTitleDidChange, object: tabManager)) { notification in
            guard let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID, workspaceId == tabManager.selectedTabId, !tabManager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspaceId) else { return }
            updateTitlebarText()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString()
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String
            scheduleTitlebarThemeRefresh(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
            sidebarSelectionState.selection = .tabs
            scheduleTitlebarTextRefresh()
        })

        // A grouped anchor's title-bar name is derived from its group's name, so
        // a group rename must refresh the cached titlebar text (#5404). Scope to
        // this view's `tabManager` (the notification's `object`) so a rename in
        // another window doesn't spuriously refresh this one.
        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspaceGroupNameDidChange, object: tabManager)) { _ in
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "focus")
            attemptCommandPaletteFocusRestoreIfNeeded()
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.onChange(of: titlebarThemeGeneration) { oldValue, newValue in
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedPanelId,
                in: observedWindow ?? webView.window
            )
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_first_responder")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedBrowser = selectedWorkspace.panels.values.compactMap({ $0 as? BrowserPanel })
                    .first(where: { $0.webView === webView }) else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedBrowser.id,
                in: observedWindow ?? webView.window
            )
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
            guard let panelId = notification.object as? UUID,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  selectedWorkspace.focusedPanelId == panelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: panelId) else { return }
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: panelId,
                in: observedWindow ?? focusedBrowser.webView.window
            )
            completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_address_bar")
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )) { _ in
            attemptCommandPaletteFocusRestoreIfNeeded()
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
            guard commandPalettePendingTextSelectionBehavior != nil else { return }
            guard let editor = notification.object as? NSTextView,
                  editor.isFieldEditor else { return }
            guard let observedWindow else { return }
            guard editor.window === observedWindow else { return }
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onChange(of: isCommandPaletteSearchFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onChange(of: isCommandPaletteRenameFocused) { _, focused in
            if focused {
                attemptCommandPaletteTextSelectionIfNeeded()
            }
        })

        view = AnyView(view.onReceive(tabManager.tabsPublisher) { tabs in
            let existingIds = Set(tabs.map { $0.id })
            if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                self.retiringWorkspaceId = nil
                workspaceHandoffFallbackTask?.cancel()
                workspaceHandoffFallbackTask = nil
            }
            if let previousSelectedWorkspaceId, !existingIds.contains(previousSelectedWorkspaceId) {
                self.previousSelectedWorkspaceId = tabManager.selectedTabId
            }
            tabManager.pruneBackgroundWorkspaceLoads(existingIds: existingIds)
            reconcileMountedWorkspaceIds(tabs: tabs)
            selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
            if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                selectedTabIds = [selectedId]
            }
            if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                if let selectedId = tabManager.selectedTabId {
                    lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                } else {
                    lastSidebarSelectionIndex = nil
                }
            }
            syncSidebarSelectedWorkspaceIds()
            applyUITestSidebarSelectionIfNeeded(tabs: tabs)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
            let tabId = SidebarDragLifecycleNotification().tabId(from: notification)
            sidebarDraggedTabId = tabId
#if DEBUG
            cmuxDebugLog(
                "sidebar.dragState.content tab=\(debugShortWorkspaceId(tabId)) " +
                "reason=\(SidebarDragLifecycleNotification().reason(from: notification))"
            )
#endif
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            toggleCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteCommands()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteSwitcher()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .defaultTerminalRegistrationDidChange)) { _ in
            refreshCachedDefaultTerminalStatus()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteSubmitRequest()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
            guard isCommandPalettePresented else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            dismissCommandPalette()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameTabInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            openCommandPaletteRenameWorkspaceInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteEditWorkspaceDescriptionRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            let shouldHandle = Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            )
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.request observed={\(debugCommandPaletteWindowSummary(observedWindow))} " +
                "requested={\(debugCommandPaletteWindowSummary(requestedWindow))} " +
                "shouldHandle=\(shouldHandle ? 1 : 0) presented=\(isCommandPalettePresented ? 1 : 0) " +
                "mode=\(debugCommandPaletteModeLabel(commandPaletteMode))"
            )
#endif
            guard shouldHandle else { return }
            openCommandPaletteWorkspaceDescriptionInput()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .commands = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
            moveCommandPaletteSelection(by: delta)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            handleCommandPaletteRenameInputInteraction()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
            guard isCommandPalettePresented else { return }
            guard case .renameInput = commandPaletteMode else { return }
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
            let requestedWindow = notification.object as? NSWindow
            guard Self.shouldHandleCommandPaletteRequest(
                observedWindow: observedWindow,
                requestedWindow: requestedWindow,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) else { return }
            presentFeedbackComposer()
        })

        view = AnyView(view.background(WindowAccessor(dedupeByWindow: false) { window in
            let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
            tmuxWorkspacePaneWindowOverlayController(for: window, createIfNeeded: tmuxOverlayState != nil)?.update(state: tmuxOverlayState)
            let overlayController = commandPaletteWindowOverlayController(for: window)
            overlayController.update(isVisible: isCommandPalettePresented) { AnyView(commandPaletteOverlay) }
        }))

        view = AnyView(view.onChange(of: bgGlassTintHex) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onChange(of: bgGlassTintOpacity) { _ in
            updateWindowGlassTint()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = true
            windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                true,
                in: window,
                isMinimalMode: isMinimalMode
            )
            AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            isFullScreen = false
            windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                false,
                in: window,
                isMinimalMode: isMinimalMode
            )
            AppDelegate.shared?.fullscreenControlsViewModel = nil
            syncTrafficLightInset()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
            clampSidebarWidthIfNeeded(availableWidth: availableWidth)
            clampRightSidebarWidthIfNeeded(availableWidth: availableWidth)
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: rightSidebarMaxWidthSetting) { _, _ in
            clampRightSidebarWidthIfNeeded()
            if rightSidebarVisible {
                schedulePortalGeometrySynchronize()
            }
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarWidth) { _ in
            let sanitized = normalizedSidebarWidth(sidebarWidth)
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
                return
            }
            if abs(sidebarState.persistedWidth - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
            }
            // Sidebar width changes are pure SwiftUI layout updates, so portal-hosted
            // terminals and browsers need an explicit post-layout geometry resync.
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
        })

        // Mirror of the `sidebarWidth` handler above for the RIGHT sidebar width.
        // The right sidebar can host the Dock — a Bonsplit tree of portal-hosted
        // terminals/browsers. Like the left sidebar, its width is a pure SwiftUI
        // layout change, so portal surfaces need an explicit coalesced geometry
        // resync each tick. Without this the Dock's surfaces miss the
        // interactive-resize flush path and the width drag renders laggily
        // compared to a native Bonsplit divider drag.
        view = AnyView(view.onChange(of: fileExplorerWidth) { _ in
            guard rightSidebarVisible else { return }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarMinimumWidthSetting) { _ in
            clampSidebarWidthIfNeeded()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: titlebarControlsStyleRawValue) { _ in
            clampSidebarWidthIfNeeded()
            updateSidebarResizerBandState()
        })

        view = AnyView(view.onChange(of: sidebarState.isVisible) { _, isVisible in
            setMinimalModeSidebarTitlebarControlsAvailable(isVisible, in: observedWindow)
            if let observedWindow {
                AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
            }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: fileExplorerState.isVisible) { isVisible in
            if !isVisible {
                _ = AppDelegate.shared?.restoreTerminalFocusAfterRightSidebarHidden(in: observedWindow)
            }
            syncFileExplorerDirectory()
            if let observedWindow {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            }
        })

        view = AnyView(view.onChange(of: fileExplorerState.mode) { _, _ in
            syncFileExplorerDirectory()
        })

        view = AnyView(view.onChange(of: sidebarMatchTerminalBackground) { _ in
            tabManager.applyWindowBackdropModeForAllTabs(reason: "sidebarMatchTerminalBackgroundChanged")
            guard sidebarState.isVisible,
                  sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue else { return }
            schedulePortalGeometrySynchronize()
        })

        view = AnyView(view.onChange(of: isMinimalMode) { _, _ in
            if let observedWindow {
                windowChrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                    isFullScreen,
                    in: observedWindow,
                    isMinimalMode: isMinimalMode
                )
                AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
                refreshWindowChromeMetrics(for: observedWindow)
                observedWindow.contentView?.needsLayout = true
                observedWindow.contentView?.superview?.needsLayout = true
                observedWindow.invalidateShadow()
            }
            schedulePortalGeometrySynchronize()
            updateSidebarResizerBandState()
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: titlebarDebugChromeSnapshot) { _, _ in
            applyTitlebarDebugChromeChange()
        })

        view = AnyView(view.onChange(of: tabManager.tabs.map(\.id)) { _ in
            syncTrafficLightInset()
        })

        view = AnyView(view.onChange(of: sidebarState.persistedWidth) { newValue in
            let sanitized = normalizedSidebarWidth(newValue)
            if abs(newValue - sanitized) > 0.5 {
                sidebarState.persistedWidth = sanitized
                return
            }
            guard !isResizerDragging else { return }
            if abs(sidebarWidth - sanitized) > 0.5 {
                sidebarWidth = sanitized
            }
        })

        view = AnyView(view.ignoresSafeArea())
        view = AnyView(view.sheet(isPresented: $isFeedbackComposerPresented) {
            SidebarFeedbackComposerSheet()
        })

        view = AnyView(view.onDisappear {
            if isResizerDragging {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                isResizerDragging = false
                sidebarDragStartWidth = nil
            }
            removeSidebarResizerPointerMonitor()
        })

        let commandPaletteOverlayView = AnyView(commandPaletteOverlay)
        let appKitWindowMutationID = appearance.appKitWindowMutationID(
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        let mainWindowAccessor = WindowAccessor(refreshID: appKitWindowMutationID) { [appearance, commandPaletteOverlayView] window in
            configureMainWindowChrome(
                window,
                appearance: appearance,
                commandPaletteOverlayView: commandPaletteOverlayView
            )
        }
        view = AnyView(view.background(mainWindowAccessor))

        return AnyView(view.cmuxAppearanceColorScheme(appearanceMode))
    }

    @MainActor
    private func configureMainWindowChrome(
        _ window: NSWindow,
        appearance: WindowAppearanceSnapshot,
        commandPaletteOverlayView: AnyView
    ) {
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.isRestorable = false
        setMinimalModeSidebarTitlebarControlsAvailable(sidebarState.isVisible, in: window)
        window.titlebarAppearsTransparent = true
        // Native AppKit titlebar dragging steals pane-tab drags in minimal
        // mode. Keep the main window immovable by default; explicit chrome
        // drag zones temporarily enable performDrag for real app moves.
        configureCmuxMainWindowDragBehavior(window)
        window.styleMask.insert(.fullSizeContentView)

        // Track this window for fullscreen notifications
        if observedWindow !== window {
            DispatchQueue.main.async {
                observedWindow = window
                isFullScreen = window.styleMask.contains(.fullScreen)
                let availableWidth = window.contentView?.bounds.width ?? window.contentLayoutRect.width
                clampSidebarWidthIfNeeded(availableWidth: availableWidth)
                clampRightSidebarWidthIfNeeded(availableWidth: availableWidth)
                syncCommandPaletteDebugStateForObservedWindow()
                installSidebarResizerPointerMonitorIfNeeded()
                updateSidebarResizerBandState()
            }
        }

        refreshWindowChromeMetrics(for: window)
        // Keep content below the titlebar so drags on Bonsplit's tab bar don't
        // get interpreted as window drags.
        // User settings decide whether window glass is active. The native Tahoe
        // NSGlassEffectView path vs the older NSVisualEffectView fallback is chosen
        // inside WindowGlassEffect.apply.
        let backdropPlan = appearance.backdropPlan(
            glassEffectAvailable: windowChrome.glassEffect.isAvailable,
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        windowChrome.nativeTitlebarBackdropCoordinator.removeNativeTitlebarBackdrop(in: window)
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1" {
            AppDelegate.shared?.updateLog.append("ui test window accessor: id=\(windowIdentifier) visible=\(window.isVisible)")
        }
#endif
        let backdropResult = windowChrome.backdropController.apply(plan: backdropPlan, to: window)
        if backdropResult.didChangeGlassRoot {
            let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(for: window)
            tmuxWorkspacePaneWindowOverlayController(for: window, createIfNeeded: tmuxOverlayState != nil)?.update(state: tmuxOverlayState)
            commandPaletteWindowOverlayController(for: window)
                .update(isVisible: isCommandPalettePresented) { commandPaletteOverlayView }
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        }
        AppDelegate.shared?.attachUpdateAccessory(to: window)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        // Let cmux supply the translucent titlebar fills. AppKit's native
        // material otherwise blends a lighter strip over the terminal area.
        windowChrome.nativeTitlebarBackdropCoordinator.syncNativeTitlebarBackdrop(
            in: window,
            enabled: true,
            usesGlassStyle: backdropResult.usesWindowGlass
        )
        AppDelegate.shared?.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore
        )
        installFileDropOverlayWhenReady(on: window, tabManager: tabManager)
    }

    private func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
        let currentTabs = tabs ?? tabManager.tabs
        let orderedTabIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? tabManager.selectedTabId
        let handoffPinnedIds = retiringWorkspaceId.map { Set([ $0 ]) } ?? []
        let pinnedIds = handoffPinnedIds
            .union(tabManager.mountedBackgroundWorkspaceLoadIds)
            .union(tabManager.debugPinnedWorkspaceLoadIds)
        let isCycleHot = tabManager.isWorkspaceCycleHot
        let shouldKeepHandoffPair = isCycleHot && !handoffPinnedIds.isEmpty
        let baseMaxMounted = shouldKeepHandoffPair
            ? WorkspaceMountPlan.maxMountedWorkspacesDuringCycle
            : WorkspaceMountPlan.maxMountedWorkspaces
        let selectedCount = effectiveSelectedId == nil ? 0 : 1
        let maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPlan(
            current: mountedWorkspaceIds,
            selected: effectiveSelectedId,
            pinnedIds: pinnedIds,
            orderedTabIds: orderedTabIds,
            isCycleHot: isCycleHot,
            maxMounted: maxMounted
        ).mountedWorkspaceIds
        let removedIds = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
        let mountedIdSet = Set(mountedWorkspaceIds)
        for workspace in currentTabs {
            workspace.setPortalRenderingEnabled(
                mountedIdSet.contains(workspace.id),
                reason: "workspaceMount"
            )
        }
#if DEBUG
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removedIds))"
                )
            } else {
                cmuxDebugLog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        }
#endif
    }

    private func addTab() {
        tabManager.addTab()
        sidebarSelectionState.selection = .tabs
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        windowChrome.backdropController.updateGlassTint(to: window, color: tintColor)
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            tabManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
            return
        }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        retiringWorkspaceId = oldSelectedId
        workspaceHandoffFallbackTask?.cancel()

#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.handoff.start id=\(snapshot.id) dt=\(debugMsText(dtMs)) old=\(debugShortWorkspaceId(oldSelectedId)) " +
                "new=\(debugShortWorkspaceId(newSelectedId))"
            )
        } else {
            cmuxDebugLog(
                "ws.handoff.start id=none old=\(debugShortWorkspaceId(oldSelectedId)) new=\(debugShortWorkspaceId(newSelectedId))"
            )
        }
#endif

        if canCompleteWorkspaceHandoffImmediately(for: newSelectedId) {
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newSelectedId))"
                )
            } else {
                cmuxDebugLog("ws.handoff.fastReady id=none selected=\(debugShortWorkspaceId(newSelectedId))")
            }
#endif
            completeWorkspaceHandoff(reason: "ready")
            return
        }

        workspaceHandoffFallbackTask = Task { [generation] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard workspaceHandoffGeneration == generation else { return }
                completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedTabId: UUID, reason: String) {
        guard focusedTabId == tabManager.selectedTabId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return true }
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Disable portal rendering for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Disabling here also cancels stale layout follow-up
        // loops that could re-show an old terminal above the newly selected workspace.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.setPortalRenderingEnabled(false, reason: "workspaceHandoff")
        }

        retiringWorkspaceId = nil
        tabManager.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(debugMsText(dtMs)) reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))"
            )
        } else {
            cmuxDebugLog("ws.handoff.complete id=none reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))")
        }
#endif
    }

    private var commandPaletteOverlay: some View {
        GeometryReader { proxy in
            let maxAllowedWidth = max(340, proxy.size.width - 260)
            let targetWidth = min(560, maxAllowedWidth)
            let workspaceDescriptionMaxEditorHeight = max(
                CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight,
                proxy.size.height - 120
            )

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleCommandPaletteBackdropClick(atContentPoint: value.location)
                            }
                    )

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("CommandPaletteBackdrop")

                VStack(spacing: 0) {
                    switch commandPaletteMode {
                    case .commands:
                        commandPaletteCommandListView
                    case .renameInput(let target):
                        commandPaletteRenameInputView(target: target)
                    case let .renameConfirm(target, proposedName):
                        commandPaletteRenameConfirmView(target: target, proposedName: proposedName)
                    case .workspaceDescriptionInput(let target):
                        commandPaletteWorkspaceDescriptionInputView(
                            target: target,
                            maxEditorHeight: workspaceDescriptionMaxEditorHeight
                        )
                    }
                }
                .frame(width: targetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            dismissCommandPalette()
        }
        .zIndex(2000)
    }

    private var commandPaletteCommandListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CommandPaletteSearchFieldRepresentable(
                    placeholder: commandPaletteSearchPlaceholder,
                    text: $commandPaletteQuery,
                    isFocused: Binding(get: { isCommandPaletteSearchFocused }, set: { isCommandPaletteSearchFocused = $0 }),
                    onSubmit: runSelectedCommandPaletteResult,
                    onEscape: { dismissCommandPalette() },
                    onMoveSelection: moveCommandPaletteSelection(by:),
                    onUnhandledNavigationKey: forwardCommandPaletteUnhandledNavigationKeyToFocusedTerminal
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            CommandPaletteCommandListRenderView(
                renderModel: commandPaletteOverlayRenderModel,
                onRunResult: runCommandPaletteResult(commandID:)
            )

            // Keep Esc-to-close behavior without showing footer controls.
            Button(action: { dismissCommandPalette() }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            resetCommandPaletteSearchFocus()
        }
        .onChange(of: commandPaletteQuery) { oldValue, newValue in
            commandPaletteSelectedResultIndex = 0
            commandPaletteSelectionAnchorCommandID = nil
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            if Self.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: oldValue,
                newQuery: newValue,
                hasVisibleResults: commandPaletteVisibleResultsScope != nil
            ) {
                cachedCommandPaletteResults = []
                commandPaletteVisibleResults = []
                commandPaletteVisibleResultsScope = nil
                commandPaletteVisibleResultsFingerprint = nil
                commandPaletteVisibleResultsVersion &+= 1
            }
            scheduleCommandPaletteResultsRefresh(query: newValue)
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteCurrentSearchFingerprint) { _ in
            Task { @MainActor in
                // Let the query-state transition settle first so the forced corpus refresh
                // cannot rebuild the old command list after deleting the ">" prefix.
                await Task.yield()
                scheduleCommandPaletteResultsRefresh(
                    query: commandPaletteQuery,
                    forceSearchCorpusRefresh: true
                )
                updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
                syncCommandPaletteDebugStateForObservedWindow()
            }
        }
        .onChange(of: commandPaletteResultsRevision) { _ in
            let resultIDs = cachedCommandPaletteResults.map(\.id)
            commandPaletteSelectedResultIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                resultIDs: resultIDs
            )
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            let visibleResultCount = commandPaletteVisibleResults.count
            updateCommandPaletteScrollTarget(resultCount: visibleResultCount, animated: false)
            syncCommandPaletteOverlayCommandListState()
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteSelectedResultIndex) { _ in
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: true)
            syncCommandPaletteOverlayCommandListState()
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private enum CommandPaletteEditorFieldStyle {
        case singleLine(
            accessibilityIdentifier: String,
            focus: FocusState<Bool>.Binding,
            onDeleteBackward: ((EventModifiers) -> BackportKeyPressResult)?
        )
        case multiline(
            accessibilityIdentifier: String,
            accessibilityLabel: String,
            focus: Binding<Bool>,
            measuredHeight: Binding<CGFloat>,
            maxHeight: CGFloat
        )
    }

    @ViewBuilder
    private func commandPaletteEditorField(
        style: CommandPaletteEditorFieldStyle,
        placeholder: String,
        text: Binding<String>,
        onSubmit: @escaping (String) -> Void,
        onEscape: @escaping () -> Void,
        onInteraction: (() -> Void)? = nil
    ) -> some View {
        switch style {
        case .singleLine(let accessibilityIdentifier, let focus, let onDeleteBackward):
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .cmuxFont(size: 13, weight: .regular)
                .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                .focused(focus)
                .accessibilityIdentifier(accessibilityIdentifier)
                .backport.onKeyPress(.delete) { modifiers in
                    onDeleteBackward?(modifiers) ?? .ignored
                }
                .onSubmit {
                    onSubmit(text.wrappedValue)
                }
                .onTapGesture {
                    onInteraction?()
                }
        case .multiline(let accessibilityIdentifier, let accessibilityLabel, let focus, let measuredHeight, let maxHeight):
            CommandPaletteMultilineTextEditorRepresentable(
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                text: text,
                isFocused: focus,
                measuredHeight: measuredHeight,
                maxHeight: maxHeight,
                onSubmit: onSubmit,
                onEscape: onEscape
            )
            .frame(height: measuredHeight.wrappedValue)
        }
    }

    private func commandPaletteRenameInputView(target: CommandPaletteRenameTarget) -> some View {
        VStack(spacing: 0) {
            commandPaletteEditorField(
                style: .singleLine(
                    accessibilityIdentifier: "CommandPaletteRenameField",
                    focus: $isCommandPaletteRenameFocused,
                    onDeleteBackward: handleCommandPaletteRenameDeleteBackward(modifiers:)
                ),
                placeholder: target.placeholder,
                text: $commandPaletteRenameDraft,
                onSubmit: { _ in continueRenameFlow(target: target) },
                onEscape: { dismissCommandPalette() },
                onInteraction: handleCommandPaletteRenameInputInteraction
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(renameInputHintText(target: target))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                continueRenameFlow(target: target)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            resetCommandPaletteRenameFocus()
        }
    }

    private func commandPaletteRenameConfirmView(
        target: CommandPaletteRenameTarget,
        proposedName: String
    ) -> some View {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName.isEmpty ? String(localized: "commandPalette.rename.clearCustomName", defaultValue: "(clear custom name)") : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .cmuxFont(size: 13, weight: .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text(renameConfirmHintText(target: target))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                applyRenameFlow(target: target, proposedName: proposedName)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func commandPaletteWorkspaceDescriptionInputView(
        target: CommandPaletteWorkspaceDescriptionTarget,
        maxEditorHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            commandPaletteEditorField(
                style: .multiline(
                    accessibilityIdentifier: "CommandPaletteWorkspaceDescriptionEditor",
                    accessibilityLabel: String(
                        localized: "command.editWorkspaceDescription.title",
                        defaultValue: "Edit Workspace Description…"
                    ),
                    focus: $commandPaletteShouldFocusWorkspaceDescriptionEditor,
                    measuredHeight: $commandPaletteWorkspaceDescriptionHeight,
                    maxHeight: maxEditorHeight
                ),
                placeholder: target.placeholder,
                text: $commandPaletteWorkspaceDescriptionDraft,
                onSubmit: { proposedDescription in
                    applyWorkspaceDescriptionFlow(target: target, proposedDescription: proposedDescription)
                },
                onEscape: { dismissCommandPalette() }
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(target.inputHint)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .onAppear {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.view.appear workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "height=\(String(format: "%.1f", commandPaletteWorkspaceDescriptionHeight)) " +
                "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
            )
#endif
            resetCommandPaletteWorkspaceDescriptionFocus()
        }
        .onChange(of: commandPaletteShouldFocusWorkspaceDescriptionEditor) { _, newValue in
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.focus.binding new=\(newValue ? 1 : 0) " +
                "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    private final class CommandPaletteNativeTextField: NSTextField {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func keyDown(with event: NSEvent) {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                super.keyDown(with: event)
                return
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return super.performKeyEquivalent(with: event)
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    // Keep navigation on the AppKit field editor so scope switches preserve arrow-key handlers.
    private struct CommandPaletteSearchFieldRepresentable: NSViewRepresentable {
        let placeholder: String
        @Binding var text: String
        @Binding var isFocused: Bool
        let onSubmit: () -> Void
        let onEscape: () -> Void
        let onMoveSelection: (Int) -> Void
        let onUnhandledNavigationKey: (NSEvent) -> Bool
        @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

        @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: CommandPaletteSearchFieldRepresentable
            var isProgrammaticMutation = false
            weak var parentField: CommandPaletteNativeTextField?
            var pendingFocusRequest: Bool?
            nonisolated(unsafe) var editorTextDidChangeObserver: NSObjectProtocol?
            weak var observedEditor: NSTextView?

            init(parent: CommandPaletteSearchFieldRepresentable) {
                self.parent = parent
            }

            deinit { editorTextDidChangeObserver.map(NotificationCenter.default.removeObserver) }

            func controlTextDidChange(_ obj: Notification) {
                guard !isProgrammaticMutation else { return }
                guard let field = obj.object as? NSTextField else { return }
                parent.text = field.stringValue
            }

            func controlTextDidBeginEditing(_ obj: Notification) {
                if let field = obj.object as? NSTextField,
                   let editor = field.currentEditor() as? NSTextView {
                    attachEditorTextDidChangeObserverIfNeeded(editor)
                }
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func controlTextDidEndEditing(_ obj: Notification) {
                detachEditorTextDidChangeObserver()
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                if let delta = commandPaletteSelectionDeltaForFieldEditorCommand(commandSelector, event: NSApp.currentEvent) {
                    parent.onMoveSelection(delta); return true
                }

                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                    return NSApp.currentEvent.map(parent.onUnhandledNavigationKey) ?? false
                case #selector(NSResponder.insertNewline(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onEscape()
                    return true
                default:
                    return false
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: event.modifierFlags,
                    chars: event.characters ?? event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode,
                    nextShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPaletteNext),
                    previousShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious)
                ) {
                    parent.onMoveSelection(delta)
                    return true
                }

                if shouldSubmitCommandPaletteWithReturn(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags,
                    mode: "single_line"
                ) {
                    parent.onSubmit()
                    return true
                }

                if event.keyCode == 53,
                   event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])
                    .isEmpty {
                    parent.onEscape()
                    return true
                }

                return false
            }

            func attachEditorTextDidChangeObserverIfNeeded(_ editor: NSTextView) {
                if observedEditor !== editor {
                    detachEditorTextDidChangeObserver()
                }
                guard editorTextDidChangeObserver == nil else { return }
                observedEditor = editor
                editorTextDidChangeObserver = NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: editor,
                    queue: .main
                ) { [weak self, weak editor] _ in
                    MainActor.assumeIsolated { if let self, !self.isProgrammaticMutation, let editor { self.parent.text = editor.string } }
                }
            }

            func detachEditorTextDidChangeObserver() {
                if let editorTextDidChangeObserver {
                    NotificationCenter.default.removeObserver(editorTextDidChangeObserver)
                    self.editorTextDidChangeObserver = nil
                }
                observedEditor = nil
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteNativeTextField {
            let field = CommandPaletteNativeTextField(frame: .zero)
            field.font = GlobalFontMagnification.systemFont(ofSize: 13)
            field.placeholderString = placeholder
            field.setAccessibilityIdentifier("CommandPaletteSearchField")
            field.delegate = context.coordinator
            field.stringValue = text
            field.isEditable = true
            field.isSelectable = true
            field.isEnabled = true
            field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            context.coordinator.parentField = field
            return field
        }

        func updateNSView(_ nsView: CommandPaletteNativeTextField, context: Context) {
            context.coordinator.parent = self
            context.coordinator.parentField = nsView
            nsView.placeholderString = placeholder
            nsView.font = GlobalFontMagnification.systemFont(ofSize: 13)

            if let editor = nsView.currentEditor() as? NSTextView {
                context.coordinator.attachEditorTextDidChangeObserverIfNeeded(editor)
                if editor.string != text, !editor.hasMarkedText() {
                    context.coordinator.isProgrammaticMutation = true
                    editor.string = text
                    nsView.stringValue = text
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if nsView.stringValue != text {
                context.coordinator.detachEditorTextDidChangeObserver()
                nsView.stringValue = text
            } else {
                context.coordinator.detachEditorTextDidChangeObserver()
            }

            guard let window = nsView.window else { return }
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView

            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let coordinator, coordinator.parent.isFocused else { return }
                    guard let nsView, let window = nsView.window else { return }
                    let firstResponder = window.firstResponder
                    let alreadyFocused =
                        firstResponder === nsView ||
                        nsView.currentEditor() != nil ||
                        ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard !alreadyFocused else { return }
                    window.makeFirstResponder(nsView)
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteNativeTextField, coordinator: Coordinator) {
            nsView.delegate = nil
            nsView.onHandleKeyEvent = nil
            coordinator.detachEditorTextDidChangeObserver()
            coordinator.parentField = nil
        }
    }

    private final class CommandPalettePassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class CommandPaletteMultilineTextView: NSTextView {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
        var onDidBecomeFirstResponder: (() -> Void)?

        override func flagsChanged(with event: NSEvent) {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.flagsChanged " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            super.flagsChanged(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.textView.becomeFirstResponder success=\(becameFirstResponder ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window?.firstResponder))"
            )
#endif
            if becameFirstResponder {
                onDidBecomeFirstResponder?()
            }
            return becameFirstResponder
        }

        override func keyDown(with event: NSEvent) {
            if hasMarkedText() {
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.keyDown markedText=1 " +
                    "\(debugCommandPaletteKeyEventSummary(event))"
                )
#endif
                super.keyDown(with: event)
                return
            }
            let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.keyDown handled=\(handled ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            if handled {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if hasMarkedText() {
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.performKeyEquivalent markedText=1 " +
                    "\(debugCommandPaletteKeyEventSummary(event))"
                )
#endif
                return super.performKeyEquivalent(with: event)
            }
            let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.performKeyEquivalent handled=\(handled ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            if handled {
                return true
            }
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.performKeyEquivalent superResult=\(result ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            return result
        }

        override func doCommand(by commandSelector: Selector) {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.doCommand selector=\(NSStringFromSelector(commandSelector)) " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.doCommand(by: commandSelector)
        }

        override func insertNewline(_ sender: Any?) {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.insertNewline " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertNewline(sender)
        }

        override func insertLineBreak(_ sender: Any?) {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.insertLineBreak " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertLineBreak(sender)
        }

        override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.insertNewlineIgnoringFieldEditor " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertNewlineIgnoringFieldEditor(sender)
        }
    }

    private final class CommandPaletteMultilineTextEditorView: NSView {
        private static var font: NSFont {
            GlobalFontMagnification.systemFont(ofSize: 13)
        }
        private static let textInset = NSSize(width: 0, height: 2)
        static var defaultMinimumHeight: CGFloat {
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return lineHeight * 5 + textInset.height * 2
        }

        private let scrollView = NSScrollView(frame: .zero)
        let textView = CommandPaletteMultilineTextView(frame: .zero)
        private let placeholderField = CommandPalettePassthroughLabel(labelWithString: "")
        private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
        var onMeasuredHeightChange: ((CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat?
        var maximumHeight: CGFloat = .greatestFiniteMagnitude {
            didSet {
                refreshMetrics()
            }
        }

        var placeholder: String = "" {
            didSet {
                placeholderField.stringValue = placeholder
                updatePlaceholderVisibility()
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            addSubview(scrollView)

            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            applyFonts()
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.textContainerInset = Self.textInset
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.heightTracksTextView = false
            textView.minSize = NSSize(width: 0, height: Self.defaultMinimumHeight)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.documentView = textView

            placeholderField.translatesAutoresizingMaskIntoConstraints = false
            placeholderField.textColor = .secondaryLabelColor
            placeholderField.lineBreakMode = .byWordWrapping
            placeholderField.maximumNumberOfLines = 0
            addSubview(placeholderField)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChange(_:)),
                name: NSText.didChangeNotification,
                object: textView
            )
            fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
                self?.applyFonts()
                self?.refreshMetrics()
            }

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

                placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: Self.textInset.height),
                placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset.width),
                placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.textInset.width),
            ])

            updatePlaceholderVisibility()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private func applyFonts() {
            let font = Self.font
            textView.font = font
            placeholderField.font = font
            textView.minSize = NSSize(width: 0, height: Self.defaultMinimumHeight)
        }

        override func layout() {
            super.layout()
            updateTextViewLayout()
            reportMeasuredHeightIfNeeded()
        }

        func refreshMetrics() {
            updatePlaceholderVisibility()
            needsLayout = true
            layoutSubtreeIfNeeded()
            reportMeasuredHeightIfNeeded()
        }

        func focusIfNeeded() {
            guard let window else {
#if DEBUG
                cmuxDebugLog("palette.wsDescription.editor.focusIfNeeded window=nil")
#endif
                return
            }
            guard window.firstResponder !== textView else {
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.focusIfNeeded alreadyFocused window={\(debugCommandPaletteWindowSummary(window))}"
                )
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.focusIfNeeded attempt window={\(debugCommandPaletteWindowSummary(window))} " +
                "frBefore=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            let didFocus = window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.focusIfNeeded result didFocus=\(didFocus ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
        }

        private func cappedMaximumHeight() -> CGFloat {
            max(Self.defaultMinimumHeight, maximumHeight)
        }

        private func naturalHeight(for width: CGFloat) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return Self.defaultMinimumHeight
            }
            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
            let contentHeight = max(lineHeight, ceil(usedRect.height))
            return max(
                Self.defaultMinimumHeight,
                ceil(contentHeight + Self.textInset.height * 2)
            )
        }

        private func updateTextViewLayout() {
            let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
            let naturalHeight = naturalHeight(for: availableWidth)
            let measuredHeight = min(cappedMaximumHeight(), naturalHeight)
            let documentHeight = max(naturalHeight, measuredHeight)
            textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: documentHeight)
        }

        private func fittingHeight() -> CGFloat {
            let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
            return min(cappedMaximumHeight(), naturalHeight(for: availableWidth))
        }

        private func reportMeasuredHeightIfNeeded() {
            let height = fittingHeight()
            guard lastReportedHeight == nil || abs((lastReportedHeight ?? height) - height) > 0.5 else { return }
            lastReportedHeight = height
            onMeasuredHeightChange?(height)
        }

        @objc
        private func textDidChange(_ notification: Notification) {
            updatePlaceholderVisibility()
            reportMeasuredHeightIfNeeded()
#if DEBUG
            let newlineCount = textView.string.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "palette.wsDescription.editor.textDidChange len=\((textView.string as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
        }

        private func updatePlaceholderVisibility() {
            placeholderField.isHidden = textView.string.isEmpty == false
        }
    }

    private struct CommandPaletteMultilineTextEditorRepresentable: NSViewRepresentable {
        static var defaultMinimumHeight: CGFloat {
            CommandPaletteMultilineTextEditorView.defaultMinimumHeight
        }

        let placeholder: String
        let accessibilityLabel: String
        let accessibilityIdentifier: String
        @Binding var text: String
        @Binding var isFocused: Bool
        @Binding var measuredHeight: CGFloat
        let maxHeight: CGFloat
        let onSubmit: (String) -> Void
        let onEscape: () -> Void
        @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: CommandPaletteMultilineTextEditorRepresentable
            var isProgrammaticMutation = false
            var pendingFocusRequest = false

            init(parent: CommandPaletteMultilineTextEditorRepresentable) {
                self.parent = parent
            }

            func textDidBeginEditing(_ notification: Notification) {
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.beginEditing focus=\(parent.isFocused ? 1 : 0) " +
                    "responder=\(debugCommandPaletteResponderSummary(notification.object as? NSResponder))"
                )
#endif
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func textDidChange(_ notification: Notification) {
                guard !isProgrammaticMutation,
                      let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.command selector=\(NSStringFromSelector(commandSelector)) " +
                    "len=\((textView.string as NSString).length) " +
                    "sel=\(textView.selectedRange().location):\(textView.selectedRange().length)"
                )
#endif
                return false
            }

            func handleDidBecomeFirstResponder() {
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.didBecomeFirstResponder focus=\(parent.isFocused ? 1 : 0)"
                )
#endif
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }

            func handleMeasuredHeight(_ height: CGFloat) {
                guard abs(parent.measuredHeight - height) > 0.5 else { return }
                DispatchQueue.main.async {
                    self.parent.measuredHeight = height
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                let normalizedFlags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])

#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.handleKeyEvent " +
                    "\(debugCommandPaletteKeyEventSummary(event)) " +
                    "normalized=\(debugCommandPaletteModifierFlagsSummary(normalizedFlags))"
                )
#endif

                if event.keyCode == 36 || event.keyCode == 76 {
                    if normalizedFlags.isEmpty {
                        let currentText = editor?.string ?? parent.text
#if DEBUG
                        cmuxDebugLog("palette.wsDescription.editor.handleKeyEvent action=submit")
                        cmuxDebugLog(
                            "palette.wsDescription.editor.handleKeyEvent submitText " +
                            "len=\((currentText as NSString).length) " +
                            "text=\"\(debugCommandPaletteTextPreview(currentText))\""
                        )
#endif
                        if parent.text != currentText {
                            parent.text = currentText
                        }
                        parent.onSubmit(currentText)
                        return true
                    }
                    if normalizedFlags == [.shift] {
#if DEBUG
                        cmuxDebugLog("palette.wsDescription.editor.handleKeyEvent action=allowShiftReturn")
#endif
                        return false
                    }
                }

                if event.keyCode == 53, normalizedFlags.isEmpty {
#if DEBUG
                    cmuxDebugLog("palette.wsDescription.editor.handleKeyEvent action=escape")
#endif
                    parent.onEscape()
                    return true
                }

#if DEBUG
                cmuxDebugLog("palette.wsDescription.editor.handleKeyEvent action=passThrough")
#endif
                return false
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteMultilineTextEditorView {
            let view = CommandPaletteMultilineTextEditorView(frame: .zero)
            view.placeholder = placeholder
            view.maximumHeight = maxHeight
            view.textView.string = text
            view.textView.delegate = context.coordinator
            view.textView.setAccessibilityLabel(accessibilityLabel)
            view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
            view.setAccessibilityIdentifier(accessibilityIdentifier)
            view.textView.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            view.textView.onDidBecomeFirstResponder = { [weak coordinator = context.coordinator] in
                coordinator?.handleDidBecomeFirstResponder()
            }
            view.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
                coordinator?.handleMeasuredHeight(height)
            }
            view.refreshMetrics()
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.editor.make focus=\(isFocused ? 1 : 0) " +
                "textLen=\((text as NSString).length) " +
                "height=\(String(format: "%.1f", measuredHeight))"
            )
#endif
            return view
        }

        func updateNSView(_ nsView: CommandPaletteMultilineTextEditorView, context: Context) {
            context.coordinator.parent = self
            nsView.placeholder = placeholder
            nsView.maximumHeight = maxHeight
            nsView.textView.setAccessibilityLabel(accessibilityLabel)
            nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
            nsView.setAccessibilityIdentifier(accessibilityIdentifier)

            if nsView.textView.string != text {
                context.coordinator.isProgrammaticMutation = true
                nsView.textView.string = text
                context.coordinator.isProgrammaticMutation = false
            }
            nsView.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
                coordinator?.handleMeasuredHeight(height)
            }
            nsView.refreshMetrics()

            guard let window = nsView.window else {
#if DEBUG
                if isFocused {
                    cmuxDebugLog(
                        "palette.wsDescription.editor.update waitingForWindow focus=1 " +
                        "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0)"
                    )
                }
#endif
                return
            }
            let isFirstResponder = window.firstResponder === nsView.textView
#if DEBUG
            if isFocused || context.coordinator.pendingFocusRequest {
                cmuxDebugLog(
                    "palette.wsDescription.editor.update focus=\(isFocused ? 1 : 0) " +
                    "isFirstResponder=\(isFirstResponder ? 1 : 0) " +
                    "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0) " +
                    "window={\(debugCommandPaletteWindowSummary(window))} " +
                    "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
                )
            }
#endif
            if isFocused, !isFirstResponder, !context.coordinator.pendingFocusRequest {
                context.coordinator.pendingFocusRequest = true
#if DEBUG
                cmuxDebugLog(
                    "palette.wsDescription.editor.update scheduleFocus window={\(debugCommandPaletteWindowSummary(window))} " +
                    "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
                )
#endif
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    guard let coordinator else { return }
                    coordinator.pendingFocusRequest = false
                    guard coordinator.parent.isFocused, let nsView else { return }
                    nsView.focusIfNeeded()
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteMultilineTextEditorView, coordinator: Coordinator) {
            nsView.textView.delegate = nil
            nsView.textView.onHandleKeyEvent = nil
            nsView.textView.onDidBecomeFirstResponder = nil
            nsView.onMeasuredHeightChange = nil
        }
    }

    private func renameInputHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceInputHint", defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabInputHint", defaultValue: "Enter a tab name. Press Enter to rename, Escape to cancel.")
        }
    }

    private func renameConfirmHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to apply this tab name, or Escape to cancel.")
        }
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        Self.commandPaletteListScope(for: commandPaletteQuery)
    }

    private var commandPaletteCurrentSearchFingerprint: Int {
        let scope = commandPaletteListScope
        return commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries,
            commandsContext: scope == .commands ? commandPaletteCachedCommandsContext() : nil
        )
    }

    nonisolated private static func commandPaletteListScope(for query: String) -> CommandPaletteListScope {
        if query.hasPrefix(Self.commandPaletteCommandsPrefix) {
            return .commands
        }
        return .switcher
    }

    static func commandPaletteShouldResetVisibleResultsForQueryTransition(
        oldQuery: String,
        newQuery: String,
        hasVisibleResults: Bool
    ) -> Bool {
        hasVisibleResults && commandPaletteListScope(for: oldQuery) != commandPaletteListScope(for: newQuery)
    }

    nonisolated static func commandPaletteListIdentity(for query: String) -> String {
        commandPaletteListScope(for: query).rawValue
    }

    private var commandPaletteSwitcherIncludesSurfaceEntries: Bool {
        Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: commandPaletteQuery
        )
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherPlaceholderAllSurfaces", defaultValue: "Search workspaces and surfaces")
                : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherEmptyAllSurfaces", defaultValue: "No workspaces or surfaces match your search.")
                : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search.")
        }
    }

    private var commandPaletteQueryForMatching: String {
        Self.commandPaletteQueryForMatching(
            query: commandPaletteQuery,
            scope: commandPaletteListScope
        )
    }

    nonisolated private static func commandPaletteRefreshQuery(
        stateQuery: String,
        observedQuery: String?
    ) -> String {
        observedQuery ?? stateQuery
    }

    nonisolated static func commandPaletteRefreshInputsForTests(
        stateQuery: String,
        observedQuery: String?,
        searchAllSurfaces: Bool
    ) -> (scope: String, matchingQuery: String, includesSurfaces: Bool) {
        let effectiveQuery = commandPaletteRefreshQuery(
            stateQuery: stateQuery,
            observedQuery: observedQuery
        )
        let scope = commandPaletteListScope(for: effectiveQuery)
        return (
            scope: scope.rawValue,
            matchingQuery: commandPaletteQueryForMatching(query: effectiveQuery, scope: scope),
            includesSurfaces: commandPaletteSwitcherIncludesSurfaceEntries(
                searchAllSurfaces: searchAllSurfaces,
                query: effectiveQuery
            )
        )
    }

    nonisolated private static func commandPaletteQueryForMatching(
        query: String,
        scope: CommandPaletteListScope
    ) -> String {
        switch scope {
        case .commands:
            let suffix = String(query.dropFirst(Self.commandPaletteCommandsPrefix.count))
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        case .switcher:
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func commandPaletteEntries(for scope: CommandPaletteListScope) -> [CommandPaletteCommand] {
        commandPaletteEntries(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntries(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> [CommandPaletteCommand] {
        switch scope {
        case .commands:
            return commandPaletteCommands(commandsContext: commandsContext ?? commandPaletteCachedCommandsContext())
        case .switcher:
            return commandPaletteSwitcherEntries(includeSurfaces: includeSurfaces)
        }
    }

    nonisolated private static func commandPaletteSwitcherIncludesSurfaceEntries(
        searchAllSurfaces: Bool,
        query: String
    ) -> Bool {
        let scope = commandPaletteListScope(for: query)
        guard scope == .switcher else { return false }
        return searchAllSurfaces && !commandPaletteQueryForMatching(query: query, scope: scope).isEmpty
    }

    private func refreshCommandPaletteSearchCorpus(
        force: Bool = false,
        query: String? = nil
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let includeSurfaces = Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: effectiveQuery
        )
        let terminalOpenTargets = resolveCommandPaletteTerminalOpenTargets(for: scope)
        if commandPaletteTerminalOpenTargetAvailability != terminalOpenTargets {
            commandPaletteTerminalOpenTargetAvailability = terminalOpenTargets
        }
        refreshCommandPaletteForkableAgentAvailabilityIfNeeded(scope: scope)
        let commandsContext = scope == .commands
            ? commandPaletteCommandsContext(terminalOpenTargets: terminalOpenTargets)
            : nil
        let fingerprint = commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        guard force || cachedCommandPaletteScope != scope || cachedCommandPaletteFingerprint != fingerprint else {
            return
        }

        let entries = commandPaletteEntries(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        commandPaletteSearchCommandsByID = CommandPaletteSearchOrchestrator.firstValueDictionary(
            entries,
            keyedBy: \.id
        )
        let searchCorpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        commandPaletteSearchCorpus = searchCorpus
        commandPaletteSearchCorpusByID = CommandPaletteSearchOrchestrator.firstValueDictionary(
            searchCorpus,
            keyedBy: \.payload
        )
        cachedCommandPaletteScope = scope
        cachedCommandPaletteFingerprint = fingerprint
        scheduleCommandPaletteSearchIndexBuild(
            entries: searchCorpus,
            scope: scope,
            fingerprint: fingerprint
        )
    }

    private func cancelCommandPaletteSearch() {
        commandPaletteSearchTask?.cancel()
        commandPaletteSearchTask = nil
    }

    private func cancelCommandPaletteSearchIndexBuild() {
        commandPaletteSearchIndexBuildTask?.cancel()
        commandPaletteSearchIndexBuildTask = nil
        commandPaletteSearchIndexBuildGeneration &+= 1
    }

    private func scheduleCommandPaletteSearchIndexBuild(
        entries: [CommandPaletteSearchCorpusEntry<String>],
        scope: CommandPaletteListScope,
        fingerprint: Int?
    ) {
        cancelCommandPaletteSearchIndexBuild()
        commandPaletteNucleoSearchIndex = nil
        let generation = commandPaletteSearchIndexBuildGeneration
        commandPaletteSearchIndexBuildTask = Task.detached(priority: .userInitiated) {
            let index = CommandPaletteNucleoSearchIndex(entries: entries)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard commandPaletteSearchIndexBuildGeneration == generation,
                      cachedCommandPaletteScope == scope,
                      cachedCommandPaletteFingerprint == fingerprint else {
                    return
                }
                commandPaletteNucleoSearchIndex = index
                commandPaletteSearchIndexBuildTask = nil
                guard index != nil else { return }
                if isCommandPalettePresented,
                   Self.commandPaletteListScope(for: commandPaletteQuery) == scope {
                    scheduleCommandPaletteResultsRefresh(
                        query: commandPaletteQuery,
                        preservePendingActivation: true
                    )
                }
            }
        }
    }

    nonisolated static func commandPaletteForkPriorityBoost(commandId: String, query: String) -> Int {
        guard CommandPaletteFuzzyMatcher.normalizeForSearch(query) == "fork",
              commandId == "palette.forkAgentConversationRight" else {
            return 0
        }
        return 10_000
    }

    private static func commandPaletteMaterializedSearchResults(
        matches: [CommandPaletteResolvedSearchMatch],
        commandsByID: [String: CommandPaletteCommand]
    ) -> [CommandPaletteSearchResult] {
        matches.compactMap { match in
            guard let command = commandsByID[match.commandID] else { return nil }
            return CommandPaletteSearchResult(
                command: command,
                score: match.score,
                titleMatchIndices: match.titleMatchIndices
            )
        }
    }

    private func setCommandPaletteVisibleResults(
        _ results: [CommandPaletteSearchResult],
        scope: CommandPaletteListScope,
        fingerprint: Int?
    ) {
        commandPaletteVisibleResults = results
        commandPaletteVisibleResultsScope = scope
        commandPaletteVisibleResultsFingerprint = fingerprint
        commandPaletteVisibleResultsVersion &+= 1
        syncCommandPaletteOverlayCommandListState()
    }

    private func commandPaletteRenderTrailingLabel(for command: CommandPaletteCommand) -> CommandPaletteRenderTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteRenderTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        if let kindLabel = command.kindLabel {
            return CommandPaletteRenderTrailingLabel(text: kindLabel, style: .kind)
        }
        return nil
    }

    private func commandPaletteOverlayCommandListStateSnapshot() -> CommandPaletteCommandListRenderState {
        let rows = commandPaletteVisibleResults.map { result in
            CommandPaletteRenderResultRow(
                id: result.id,
                title: result.command.title,
                matchedIndices: result.titleMatchIndices,
                trailingLabel: commandPaletteRenderTrailingLabel(for: result.command)
            )
        }
        let selectedIndex = commandPaletteSelectedIndex(resultCount: rows.count)
        return CommandPaletteCommandListRenderState(
            resultsVersion: commandPaletteVisibleResultsVersion,
            emptyStateText: commandPaletteEmptyStateText,
            listIdentity: Self.commandPaletteListIdentity(for: commandPaletteQuery),
            rows: rows,
            selectedIndex: selectedIndex,
            shouldShowEmptyState: commandPaletteShouldShowEmptyState,
            scrollTargetID: commandPaletteScrollTargetID(rows: rows),
            scrollTargetAnchor: commandPaletteScrollTargetAnchor
        )
    }

    private func commandPaletteScrollTargetID(rows: [CommandPaletteRenderResultRow]) -> String? {
        guard let index = commandPaletteScrollTargetIndex,
              rows.indices.contains(index) else {
            return nil
        }
        return rows[index].id
    }

    private func syncCommandPaletteOverlayCommandListState() {
        commandPaletteOverlayRenderModel.scheduleCommandListUpdate(commandPaletteOverlayCommandListStateSnapshot())
    }

    private func scheduleCommandPaletteResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false,
        preservePendingActivation: Bool = false
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let matchingQuery = Self.commandPaletteQueryForMatching(
            query: effectiveQuery,
            scope: scope
        )

        refreshCommandPaletteSearchCorpus(
            force: forceSearchCorpusRefresh,
            query: effectiveQuery
        )

        commandPaletteSearchRequestID &+= 1
        let requestID = commandPaletteSearchRequestID
        let fingerprint = cachedCommandPaletteFingerprint
        let searchCorpus = commandPaletteSearchCorpus
        let searchCorpusByID = commandPaletteSearchCorpusByID
        let searchIndex = commandPaletteNucleoSearchIndex
        let commandsByID = commandPaletteSearchCommandsByID
        let usageHistory = commandPaletteUsageHistoryByCommandId
        let queryIsEmpty = CommandPaletteFuzzyMatcher.preparedQuery(matchingQuery).isEmpty
        let historyTimestamp = Date().timeIntervalSince1970
        let additionalScoreBoost: (String, Bool) -> Int = { commandId, _ in
            Self.commandPaletteForkPriorityBoost(commandId: commandId, query: matchingQuery)
        }
        let visiblePreviewResultLimit = Self.commandPaletteVisiblePreviewResultLimit
        if preservePendingActivation {
            commandPalettePendingActivation = Self.commandPalettePendingActivation(
                commandPalettePendingActivation,
                rebasedTo: requestID
            )
        } else {
            commandPalettePendingActivation = nil
        }
        cancelCommandPaletteSearch()
        if CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
            hasVisibleResultsForScope: commandPaletteVisibleResultsScope == scope,
            hasSearchIndex: searchIndex != nil,
            corpusCount: searchCorpus.count
        ) {
            let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
                searchIndex: searchIndex,
                searchCorpus: searchCorpus,
                searchCorpusByID: searchCorpusByID,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                additionalScoreBoost: additionalScoreBoost
            )
            cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                matches: matches,
                commandsByID: commandsByID
            )
            let resultIDs = cachedCommandPaletteResults.map(\.id)
            let pendingActivationResolution = Self.commandPalettePendingActivationResolution(
                commandPalettePendingActivation,
                requestID: requestID,
                resultIDs: resultIDs
            )
            commandPaletteResolvedSearchRequestID = requestID
            commandPaletteResolvedSearchScope = scope
            commandPaletteResolvedSearchFingerprint = fingerprint
            commandPaletteResolvedMatchingQuery = matchingQuery
            isCommandPaletteSearchPending = false
            setCommandPaletteVisibleResults(
                cachedCommandPaletteResults,
                scope: scope,
                fingerprint: fingerprint
            )
            if pendingActivationResolution.shouldClearPendingActivation {
                commandPalettePendingActivation = nil
            }
            commandPaletteResultsRevision &+= 1
            if let resolvedActivation = pendingActivationResolution.resolvedActivation {
                runCommandPaletteResolvedActivation(resolvedActivation)
            }
            return
        }
        let previewCandidateCommandIDs: [String]
        if commandPaletteVisibleResultsScope == scope,
           commandPaletteVisibleResultsFingerprint == fingerprint,
           !commandPaletteVisibleResults.isEmpty {
            previewCandidateCommandIDs = CommandPaletteSearchOrchestrator.previewCandidateCommandIDs(
                resultIDs: commandPaletteVisibleResults.map(\.id),
                limit: Self.commandPaletteVisiblePreviewCandidateLimit
            )
        } else {
            previewCandidateCommandIDs = []
        }
        let shouldApplyPreviewResults = scope == .commands || !previewCandidateCommandIDs.isEmpty
        isCommandPaletteSearchPending = true
        syncCommandPaletteOverlayCommandListState()

        commandPaletteSearchTask = Task.detached(priority: .userInitiated) {
            let previewMatches = shouldApplyPreviewResults
                ? CommandPaletteSearchOrchestrator().previewSearchMatches(
                    scope: scope,
                    searchIndex: searchIndex,
                    searchCorpus: searchCorpus,
                    candidateCommandIDs: previewCandidateCommandIDs,
                    searchCorpusByID: searchCorpusByID,
                    query: matchingQuery,
                    usageHistory: usageHistory,
                    queryIsEmpty: queryIsEmpty,
                    historyTimestamp: historyTimestamp,
                    additionalScoreBoost: additionalScoreBoost,
                    resultLimit: visiblePreviewResultLimit
                )
                : []

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = Self.commandPaletteListScope(for: commandPaletteQuery)
                let currentMatchingQuery = Self.commandPaletteQueryForMatching(
                    query: commandPaletteQuery,
                    scope: currentScope
                )
                let shouldApplyPreview = commandPaletteSearchRequestID == requestID
                    && isCommandPalettePresented
                    && currentScope == scope
                    && currentMatchingQuery == matchingQuery
                    && cachedCommandPaletteFingerprint == fingerprint
                    && isCommandPaletteSearchPending
                guard shouldApplyPreview else {
                    return
                }
                guard shouldApplyPreviewResults else {
                    return
                }

                let previewResults = Self.commandPaletteMaterializedSearchResults(
                    matches: previewMatches,
                    commandsByID: commandPaletteSearchCommandsByID
                )
                setCommandPaletteVisibleResults(
                    previewResults,
                    scope: scope,
                    fingerprint: fingerprint
                )
                updateCommandPaletteScrollTarget(resultCount: previewResults.count, animated: false)
                syncCommandPaletteOverlayCommandListState()
                syncCommandPaletteDebugStateForObservedWindow()
            }

            guard !Task.isCancelled else { return }

            let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
                searchIndex: searchIndex,
                searchCorpus: searchCorpus,
                searchCorpusByID: searchCorpusByID,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                additionalScoreBoost: additionalScoreBoost,
                shouldCancel: { Task.isCancelled }
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = Self.commandPaletteListScope(for: commandPaletteQuery)
                let currentMatchingQuery = Self.commandPaletteQueryForMatching(
                    query: commandPaletteQuery,
                    scope: currentScope
                )
                let shouldApplyResults = commandPaletteSearchRequestID == requestID
                    && isCommandPalettePresented
                    && currentScope == scope
                    && currentMatchingQuery == matchingQuery
                    && cachedCommandPaletteFingerprint == fingerprint
                guard shouldApplyResults else {
                    return
                }

                cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                    matches: matches,
                    commandsByID: commandPaletteSearchCommandsByID
                )
                let resultIDs = cachedCommandPaletteResults.map(\.id)
                let pendingActivationResolution = Self.commandPalettePendingActivationResolution(
                    commandPalettePendingActivation,
                    requestID: requestID,
                    resultIDs: resultIDs
                )
                commandPaletteResolvedSearchRequestID = requestID
                commandPaletteResolvedSearchScope = scope
                commandPaletteResolvedSearchFingerprint = fingerprint
                commandPaletteResolvedMatchingQuery = matchingQuery
                isCommandPaletteSearchPending = false
                setCommandPaletteVisibleResults(
                    cachedCommandPaletteResults,
                    scope: scope,
                    fingerprint: fingerprint
                )
                if pendingActivationResolution.shouldClearPendingActivation {
                    commandPalettePendingActivation = nil
                }
                commandPaletteResultsRevision &+= 1
                if commandPaletteSearchRequestID == requestID {
                    commandPaletteSearchTask = nil
                }
                if let resolvedActivation = pendingActivationResolution.resolvedActivation {
                    runCommandPaletteResolvedActivation(resolvedActivation)
                }
            }
        }
    }

    private func commandPaletteEntriesFingerprint(for scope: CommandPaletteListScope) -> Int {
        commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries
        )
    }

    private func commandPaletteEntriesFingerprint(
        for scope: CommandPaletteListScope,
        includeSurfaces: Bool,
        commandsContext: CommandPaletteCommandsContext? = nil
    ) -> Int {
        switch scope {
        case .commands:
            return commandPaletteCommandsFingerprint(
                commandsContext: commandsContext ?? commandPaletteCachedCommandsContext()
            )
        case .switcher:
            return commandPaletteSwitcherEntriesFingerprint(includeSurfaces: includeSurfaces)
        }
    }

    private func commandPaletteCommandsFingerprint(commandsContext: CommandPaletteCommandsContext) -> Int {
        var hasher = Hasher()
        hasher.combine(commandsContext.snapshot.fingerprint())
        hasher.combine(cmuxConfigStore.configRevision)
        return hasher.finalize()
    }

    private func commandPaletteSwitcherEntriesFingerprint(includeSurfaces: Bool) -> Int {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        let fingerprintContexts = windowContexts.map { context in
            CommandPaletteSwitcherFingerprintContext(
                windowId: context.windowId,
                windowLabel: context.windowLabel,
                selectedWorkspaceId: context.selectedWorkspaceId,
                workspaces: commandPaletteOrderedSwitcherWorkspaces(for: context).map { workspace in
                    CommandPaletteSwitcherFingerprintWorkspace(
                        id: workspace.id,
                        displayName: workspaceDisplayName(workspace),
                        metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                        surfaces: includeSurfaces
                            ? commandPaletteOrderedSwitcherPanels(for: workspace).compactMap { panelId in
                                guard let panel = workspace.panels[panelId] else { return nil }
                                return CommandPaletteSwitcherFingerprintSurface(
                                    id: panelId,
                                    displayName: panelDisplayName(
                                        workspace: workspace,
                                        panelId: panelId,
                                        fallback: panel.displayTitle
                                    ),
                                    kindLabel: commandPaletteSurfaceKindLabel(for: panel.panelType),
                                    metadata: commandPaletteSurfaceSearchMetadata(
                                        for: workspace,
                                        panelId: panelId
                                    )
                                )
                            }
                            : []
                    )
                }
            )
        }
        return CommandPaletteSwitcherFingerprintContext.fingerprint(windowContexts: fingerprintContexts)
    }

    private static func commandPaletteHighlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(.primary)
        }

        let chars = Array(title)
        var index = 0
        var result = Text("")

        while index < chars.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < chars.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            let segment = String(chars[index..<end])
            if isMatched {
                result = result + Text(segment).foregroundColor(.blue)
            } else {
                result = result + Text(segment).foregroundColor(.primary)
            }
            index = end
        }

        return result
    }

    @ViewBuilder
    private static func commandPaletteRenderTrailingLabelView(_ trailingLabel: CommandPaletteRenderTrailingLabel?) -> some View {
        if let trailingLabel {
            switch trailingLabel.style {
            case .shortcut:
                Text(trailingLabel.text)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            case .kind:
                Text(trailingLabel.text)
                    .cmuxFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    static func commandPaletteRenderResultLabelContent(
        title: String,
        matchedIndices: Set<Int>,
        trailingLabel: CommandPaletteRenderTrailingLabel?
    ) -> some View {
        HStack(spacing: 8) {
            commandPaletteHighlightedTitleText(
                title,
                matchedIndices: matchedIndices
            )
                .cmuxFont(size: 13, weight: .regular)
                .lineLimit(1)
            Spacer()
            commandPaletteRenderTrailingLabelView(trailingLabel)
        }
    }

    private func commandPaletteSwitcherEntries(includeSurfaces: Bool) -> [CommandPaletteCommand] {
        let windowContexts = commandPaletteSwitcherWindowContexts()
        guard !windowContexts.isEmpty else { return [] }

        var entries: [CommandPaletteCommand] = []
        let estimatedCount = windowContexts.reduce(0) { partial, context in
            let workspaceCount = context.tabManager.tabs.count
            guard includeSurfaces else { return partial + workspaceCount }
            let surfaceCount = context.tabManager.tabs.reduce(0) { count, workspace in
                count + commandPaletteOrderedSwitcherPanels(for: workspace).count
            }
            return partial + workspaceCount + surfaceCount
        }
        entries.reserveCapacity(estimatedCount)
        var nextRank = 0

        for context in windowContexts {
            let workspaces = commandPaletteOrderedSwitcherWorkspaces(for: context)
            guard !workspaces.isEmpty else { continue }

            let windowId = context.windowId
            let windowTabManager = context.tabManager
            let windowKeywords = commandPaletteWindowKeywords(windowLabel: context.windowLabel)
            for workspace in workspaces {
                let workspaceName = workspaceDisplayName(workspace)
                let workspaceCommandId = "switcher.workspace.\(workspace.id.uuidString.lowercased())"
                let workspaceKeywords = CommandPaletteSwitcherSearchIndexer(
                    baseKeywords: [
                        "workspace",
                        "switch",
                        "go",
                        "open",
                        workspaceName
                    ] + windowKeywords,
                    metadata: commandPaletteWorkspaceSearchMetadata(for: workspace),
                    detail: .workspace
                ).keywords
                let workspaceId = workspace.id
                entries.append(
                    CommandPaletteCommand(
                        id: workspaceCommandId,
                        rank: nextRank,
                        title: workspaceName,
                        subtitle: Self.commandPaletteSwitcherSubtitle(base: String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace"), windowLabel: context.windowLabel),
                        shortcutHint: nil,
                        kindLabel: String(localized: "commandPalette.kind.workspace", defaultValue: "Workspace"),
                        keywords: workspaceKeywords,
                        dismissOnRun: true,
                        action: {
                            focusCommandPaletteSwitcherTarget(
                                windowId: windowId,
                                tabManager: windowTabManager,
                                workspaceId: workspaceId
                            )
                        }
                    )
                )
                nextRank += 1

                guard includeSurfaces else { continue }

                for panelId in commandPaletteOrderedSwitcherPanels(for: workspace) {
                    guard let panel = workspace.panels[panelId] else { continue }
                    let surfaceName = panelDisplayName(
                        workspace: workspace,
                        panelId: panelId,
                        fallback: panel.displayTitle
                    )
                    let surfaceKindLabel = commandPaletteSurfaceKindLabel(for: panel.panelType)
                    let surfaceCommandId = "switcher.surface.\(panelId.uuidString.lowercased())"
                    let surfaceKeywords = CommandPaletteSwitcherSearchIndexer(
                        baseKeywords: [
                            "surface",
                            "tab",
                            "switch",
                            "go",
                            "open",
                            surfaceName,
                            workspaceName
                        ] + commandPaletteSurfaceKeywords(for: panel.panelType) + windowKeywords,
                        metadata: commandPaletteSurfaceSearchMetadata(for: workspace, panelId: panelId),
                        detail: .surface
                    ).keywords
                    entries.append(
                        CommandPaletteCommand(
                            id: surfaceCommandId,
                            rank: nextRank,
                            title: surfaceName,
                            subtitle: Self.commandPaletteSwitcherSubtitle(base: workspaceName, windowLabel: context.windowLabel),
                            shortcutHint: nil,
                            kindLabel: surfaceKindLabel,
                            keywords: surfaceKeywords,
                            dismissOnRun: true,
                            action: {
                                focusCommandPaletteSwitcherSurfaceTarget(
                                    windowId: windowId,
                                    tabManager: windowTabManager,
                                    workspaceId: workspace.id,
                                    panelId: panelId
                                )
                            }
                        )
                    )
                    nextRank += 1
                }
            }
        }

        return entries
    }

    private func commandPaletteSwitcherWindowContexts() -> [CommandPaletteSwitcherWindowContext] {
        let fallback = CommandPaletteSwitcherWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            selectedWorkspaceId: tabManager.selectedTabId,
            windowLabel: nil
        )

        guard let appDelegate = AppDelegate.shared else { return [fallback] }
        let summaries = appDelegate.listMainWindowSummaries()
        guard !summaries.isEmpty else { return [fallback] }

        let orderedSummaries = summaries.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.windowId == windowId
            let rhsIsCurrent = rhs.windowId == windowId
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        var windowLabelById: [UUID: String] = [:]
        if orderedSummaries.count > 1 {
            for (index, summary) in orderedSummaries.enumerated() where summary.windowId != windowId {
                windowLabelById[summary.windowId] = String(localized: "commandPalette.switcher.windowLabel", defaultValue: "Window \(index + 1)")
            }
        }

        var contexts: [CommandPaletteSwitcherWindowContext] = []
        var seenWindowIds: Set<UUID> = []
        for summary in orderedSummaries {
            guard let manager = appDelegate.tabManagerFor(windowId: summary.windowId) else { continue }
            guard seenWindowIds.insert(summary.windowId).inserted else { continue }
            contexts.append(
                CommandPaletteSwitcherWindowContext(
                    windowId: summary.windowId,
                    tabManager: manager,
                    selectedWorkspaceId: summary.selectedWorkspaceId,
                    windowLabel: windowLabelById[summary.windowId]
                )
            )
        }

        if contexts.isEmpty {
            return [fallback]
        }
        return contexts
    }

    private static func commandPaletteSwitcherSubtitle(base: String, windowLabel: String?) -> String {
        guard let windowLabel else { return base }
        return "\(base) • \(windowLabel)"
    }

    private func commandPaletteWindowKeywords(windowLabel: String?) -> [String] {
        guard let windowLabel else { return [] }
        return ["window", windowLabel.lowercased()]
    }

    private func commandPaletteOrderedSwitcherWorkspaces(
        for context: CommandPaletteSwitcherWindowContext
    ) -> [Workspace] {
        var workspaces = context.tabManager.tabs
        guard !workspaces.isEmpty else { return [] }

        let selectedWorkspaceId = context.selectedWorkspaceId ?? context.tabManager.selectedTabId
        if let selectedWorkspaceId,
           let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
            let selectedWorkspace = workspaces.remove(at: selectedIndex)
            workspaces.insert(selectedWorkspace, at: 0)
        }

        return workspaces
    }

    private func commandPaletteOrderedSwitcherPanels(for workspace: Workspace) -> [UUID] {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        guard orderedPanelIds.count < workspace.panels.count else { return orderedPanelIds }

        var panelIds = orderedPanelIds
        var seen = Set(orderedPanelIds)
        for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where seen.insert(panelId).inserted {
            panelIds.append(panelId)
        }
        return panelIds
    }

    private func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(
                workspaceId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true
            )
        }
    }

    private func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(
                workspaceId,
                surfaceId: panelId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true
            )
        }
    }

    private func commandPaletteWorkspaceSearchMetadata(for workspace: Workspace) -> CommandPaletteSwitcherSearchMetadata {
        // Keep workspace rows coarse and stable for predictable workspace switching queries.
        let directories = [workspace.currentDirectory]
        let branches = [workspace.gitBranch?.branch].compactMap { $0 }
        let ports = workspace.listeningPorts
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports,
            description: workspace.customDescription
        )
    }
    private func commandPaletteSurfaceSearchMetadata(
        for workspace: Workspace,
        panelId: UUID
    ) -> CommandPaletteSwitcherSearchMetadata {
        let directories = [workspace.panelDirectories[panelId]].compactMap { $0 }
        let branches = [workspace.panelGitBranches[panelId]?.branch].compactMap { $0 }
        let ports = workspace.surfaceListeningPorts[panelId] ?? []
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
    }
    private func commandPaletteSurfaceKindLabel(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal:
            return String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "commandPalette.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "commandPalette.kind.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "commandPalette.kind.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            return String(localized: "commandPalette.kind.rightSidebarTool", defaultValue: "Tool")
        case .customSidebar:
            return String(localized: "commandPalette.kind.customSidebar", defaultValue: "Custom Sidebar")
        case .agentSession:
            return String(localized: "commandPalette.kind.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "commandPalette.kind.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        }
    }
    private func commandPaletteSurfaceKeywords(for panelType: PanelType) -> [String] {
        switch panelType {
        case .terminal:
            return ["terminal", "shell", "console"]
        case .browser:
            return ["browser", "web", "page"]
        case .markdown:
            return ["markdown", "note", "preview"]
        case .filePreview:
            return ["file", "preview", "text", "pdf", "image", "audio", "video"]
        case .rightSidebarTool:
            return ["tool", "files", "find", "vault", "sidebar"]
        case .customSidebar:
            return ["custom", "sidebar", "pane"]
        case .agentSession:
            return ["agent", "codex", "claude", "opencode", "react", "solid"]
        case .project:
            return ["project", "xcode", "build", "settings", "schemes", "targets"]
        case .extensionBrowser:
            return ["sidebar", "extensions", "extensionkit", "browser"]
        }
    }
    private func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteTerminalOpenTargetAvailability
        )
    }
    private func resolveCommandPaletteTerminalOpenTargets(
        for scope: CommandPaletteListScope
    ) -> Set<TerminalDirectoryOpenTarget> {
        guard scope == .commands,
              focusedPanelContext?.panel.panelType == .terminal else {
            return []
        }
        return TerminalDirectoryOpenTarget.availableTargets()
    }

    static func commandPaletteForkableAgentPanelKey(workspaceId: UUID, panelId: UUID) -> String {
        "\(workspaceId.uuidString):\(panelId.uuidString)"
    }

    enum CommandPaletteForkSnapshotAvailability {
        case unsupported
        case supportedWithoutProbe
        case requiresProbe
    }

    static func commandPaletteSnapshotForkAvailability(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> CommandPaletteForkSnapshotAvailability {
        guard snapshot.forkCommand != nil else { return .unsupported }
        if isRemoteTerminal,
           snapshot.forkStartupInput(allowLauncherScript: false) == nil {
            return .unsupported
        }
        switch snapshot.kind {
        case .claude, .codex:
            return .supportedWithoutProbe
        case .opencode:
            return snapshot.launchCommand?.launcher == "omo" || isRemoteTerminal ? .supportedWithoutProbe : .requiresProbe
        case .custom:
            return .supportedWithoutProbe
        default:
            return .unsupported
        }
    }

    static func commandPaletteForkSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot
    ) -> String {
        let launchCommand = snapshot.launchCommand
        let launchArguments = launchCommand?.arguments.joined(separator: "\u{1f}") ?? ""
        let parts: [String] = [
            snapshot.kind.rawValue,
            snapshot.sessionId,
            snapshot.workingDirectory ?? "",
            launchCommand?.launcher ?? "",
            launchCommand?.executablePath ?? "",
            launchArguments,
            launchCommand?.workingDirectory ?? "",
            launchCommand?.source ?? "",
            snapshot.forkCommand ?? ""
        ]
        return parts.joined(separator: "\u{1e}")
    }

    static func commandPaletteForkCacheFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        fallbackFingerprint: String?
    ) -> String {
        fallbackFingerprint ?? commandPaletteForkSnapshotFingerprint(snapshot)
    }

    static func commandPaletteForkableAgentProbeResultMatches(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool
    ) -> Bool {
        guard supportedPanelKeys.contains(panelKey),
              supportedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal else {
            return false
        }
        guard let expectedSnapshotFingerprint else {
            return true
        }
        return snapshotFingerprintsByPanelKey[panelKey] == expectedSnapshotFingerprint
    }

    static func commandPaletteShouldReuseForkableAgentProbeResult(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        !panelChanged && !cachedResultHadFallback && commandPaletteForkableAgentProbeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    static func commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
        panelKey: String,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool,
        cachedResultHadFallback: Bool,
        panelChanged: Bool
    ) -> Bool {
        panelChanged || cachedResultHadFallback || !commandPaletteForkableAgentProbeResultMatches(
            panelKey: panelKey,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: expectedSnapshotFingerprint,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    static func commandPaletteForkMatchedFallbackProbeResultHadFallback(
        cachedResultHadFallback: Bool?
    ) -> Bool {
        cachedResultHadFallback ?? true
    }

    static func commandPalettePanelHasForkableAgent(
        workspaceId: UUID,
        panelId: UUID,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool] = [:],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false
    ) -> Bool {
        let panelKey = commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        if supportedPanelKeys.contains(panelKey) {
            if let supportedRemoteContext = supportedRemoteContextsByPanelKey[panelKey],
               supportedRemoteContext != isRemoteTerminal {
                return false
            }
            if let fallbackSnapshot {
                return commandPaletteSnapshotForkAvailability(
                    fallbackSnapshot,
                    isRemoteTerminal: isRemoteTerminal
                ) != .unsupported
            }
            return true
        }
        return false
    }

    private func refreshCommandPaletteForkableAgentAvailabilityIfNeeded(scope: CommandPaletteListScope) {
        guard scope == .commands,
              let panelContext = focusedPanelContext,
              panelContext.panel.panelType == .terminal else {
            commandPaletteForkableAgentActivePanelKey = nil
            cancelCommandPaletteForkableAgentAvailabilityProbe()
            return
        }

        let workspaceId = panelContext.workspace.id
        let panelId = panelContext.panelId
        let isRemoteTerminal = panelContext.workspace.isRemoteTerminalSurface(panelId)
        let panelKey = Self.commandPaletteForkableAgentPanelKey(workspaceId: workspaceId, panelId: panelId)
        let panelChanged = commandPaletteForkableAgentActivePanelKey != panelKey
        commandPaletteForkableAgentActivePanelKey = panelKey
        let fallbackSnapshot = panelContext.workspace.restoredAgentSnapshotsByPanelId[panelId]

        if let fallbackSnapshot {
            let fallbackFingerprint = Self.commandPaletteForkSnapshotFingerprint(fallbackSnapshot)
            if let cachedFingerprint = commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey],
               cachedFingerprint != fallbackFingerprint {
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
            }
            switch Self.commandPaletteSnapshotForkAvailability(
                fallbackSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) {
            case .supportedWithoutProbe:
                let probeResultMatches = Self.commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                        Self.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                            cachedResultHadFallback: commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey]
                        )
                } else {
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                if panelChanged || !probeResultMatches {
                    startCommandPaletteForkableAgentAvailabilityProbe(
                        panelKey: panelKey,
                        workspaceId: workspaceId,
                        panelId: panelId,
                        fallbackSnapshot: fallbackSnapshot,
                        fallbackFingerprint: fallbackFingerprint,
                        isRemoteTerminal: isRemoteTerminal
                    )
                }
                return
            case .unsupported:
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                return
            case .requiresProbe:
                let probeResultMatches = Self.commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                        Self.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                            cachedResultHadFallback: commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey]
                        )
                }
                if probeResultMatches && !panelChanged {
                    return
                }
                if !probeResultMatches {
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                startCommandPaletteForkableAgentAvailabilityProbe(
                    panelKey: panelKey,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    fallbackSnapshot: fallbackSnapshot,
                    fallbackFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                return
            }
        }

        let cachedResultHadFallback = commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] == true
        if Self.commandPaletteShouldReuseForkableAgentProbeResult(
            panelKey: panelKey,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        ) {
            return
        }

        if Self.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
            panelKey: panelKey,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged
        ) {
            commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
            commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
        }
        startCommandPaletteForkableAgentAvailabilityProbe(
            panelKey: panelKey,
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: nil,
            fallbackFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    private func startCommandPaletteForkableAgentAvailabilityProbe(
        panelKey: String,
        workspaceId: UUID,
        panelId: UUID,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        fallbackFingerprint: String?,
        isRemoteTerminal: Bool
    ) {
        let probeFingerprint = "\(fallbackFingerprint ?? "")\u{1f}\(isRemoteTerminal ? "remote" : "local")"
        if let task = commandPaletteForkableAgentAvailabilityTasksByPanelKey[panelKey] {
            guard commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] != probeFingerprint else { return }
            task.cancel()
            commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
        }
        let probeID = UUID()
        commandPaletteForkableAgentProbeIDsByPanelKey[panelKey] = probeID
        commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] = probeFingerprint

        commandPaletteForkableAgentAvailabilityTasksByPanelKey[panelKey] = Task {
            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard !Task.isCancelled else { return }
            let indexSnapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId)
            let snapshot = indexSnapshot ?? fallbackSnapshot
            let supportsFork: Bool
            if let snapshot {
                supportsFork = await AgentForkSupport.supportsFork(
                    snapshot: snapshot,
                    isRemoteContext: isRemoteTerminal
                )
            } else {
                supportsFork = false
            }
#if DEBUG
            cmuxDebugLog(
                "palette.forkProbe panel=\(panelId.uuidString.prefix(5)) " +
                    "indexSnapshot=\(indexSnapshot != nil ? 1 : 0) " +
                    "fallbackSnapshot=\(fallbackSnapshot != nil ? 1 : 0) " +
                    "kind=\(snapshot?.kind.rawValue ?? "none") " +
                    "session=\(snapshot.map { String($0.sessionId.prefix(8)) } ?? "none") " +
                    "launcher=\(snapshot?.launchCommand?.launcher ?? "none") " +
                    "supportsFork=\(supportsFork ? 1 : 0)"
            )
#endif
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard commandPaletteForkableAgentProbeIDsByPanelKey[panelKey] == probeID else { return }
                guard commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] == probeFingerprint else { return }
                if let fallbackFingerprint,
                   let currentContext = focusedPanelContext,
                   currentContext.workspace.id == workspaceId,
                   currentContext.panelId == panelId,
                   let currentFallbackSnapshot = currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId],
                   Self.commandPaletteForkSnapshotFingerprint(currentFallbackSnapshot) != fallbackFingerprint {
                    commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)
                    return
                }
                let wasSupported = commandPaletteForkableAgentSupportedPanelKeys.contains(panelKey)
                let hadCachedSnapshot = commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] != nil
                let shouldRefreshResults: Bool
                if supportsFork {
                    shouldRefreshResults = !wasSupported
                    commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    if let snapshot {
                        commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
                        commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkCacheFingerprint(
                            snapshot: snapshot,
                            fallbackFingerprint: fallbackFingerprint
                        )
                        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                            indexSnapshot == nil && fallbackSnapshot != nil
                    }
                } else {
                    shouldRefreshResults = wasSupported || hadCachedSnapshot
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
                }
                commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)
                if shouldRefreshResults,
                   isCommandPalettePresented,
                   commandPaletteForkableAgentActivePanelKey == panelKey {
                    scheduleCommandPaletteResultsRefresh(
                        query: commandPaletteQuery,
                        forceSearchCorpusRefresh: true
                    )
                }
            }
        }
    }

    private func cancelCommandPaletteForkableAgentAvailabilityProbe() {
        for task in commandPaletteForkableAgentAvailabilityTasksByPanelKey.values {
            task.cancel()
        }
        commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeAll()
        commandPaletteForkableAgentProbeIDsByPanelKey.removeAll()
        commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeAll()
    }

    private func cancelCommandPaletteForkableAgentAvailabilityProbe(for panelKey: String) {
        commandPaletteForkableAgentAvailabilityTasksByPanelKey.removeValue(forKey: panelKey)?.cancel()
        commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
    }

    private func refreshCachedDefaultTerminalStatus(refreshSearchCorpusIfPresented: Bool = true) {
        let isDefault = DefaultTerminalRegistration.currentStatus().isDefault
        guard cachedDefaultTerminalIsDefault != isDefault else { return }

        cachedDefaultTerminalIsDefault = isDefault
        cachedCommandPaletteFingerprint = nil
        if refreshSearchCorpusIfPresented, isCommandPalettePresented {
            scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true, preservePendingActivation: true)
            syncCommandPaletteOverlayCommandListState()
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private func commandPaletteCommandsContext(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>
    ) -> CommandPaletteCommandsContext {
        let cliInstalledInPATH = AppDelegate.shared?.isCmuxCLIInstalledInPATH() ?? false
        var snapshot = commandPaletteContextSnapshot(terminalOpenTargets: terminalOpenTargets)
        snapshot.setBool(CommandPaletteContextKeys.cliInstalledInPATH, cliInstalledInPATH)
        snapshot.setBool(
            CommandPaletteContextKeys.defaultTerminalIsDefault,
            cachedDefaultTerminalIsDefault
        )
        return CommandPaletteCommandsContext(
            snapshot: snapshot
        )
    }

    private func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            let configuredPaletteAction = commandPaletteConfigActionID(for: contribution.commandId)
                .flatMap { cmuxConfigStore.resolvedAction(id: $0) }
            if let configuredPaletteAction, !configuredPaletteAction.palette {
                continue
            }
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: configuredPaletteAction?.title ?? contribution.title(context),
                    subtitle: configuredPaletteAction?.subtitle ?? contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution, context: context),
                    kindLabel: nil,
                    keywords: configuredPaletteAction?.keywords.isEmpty == false
                        ? configuredPaletteAction?.keywords ?? contribution.keywords
                        : contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteConfigActionID(for commandId: String) -> String? {
        switch commandId {
        case "palette.newTerminalTab":
            return CmuxSurfaceTabBarBuiltInAction.newTerminal.configID
        case "palette.newBrowserTab":
            return CmuxSurfaceTabBarBuiltInAction.newBrowser.configID
        case "palette.terminalSplitRight":
            return CmuxSurfaceTabBarBuiltInAction.splitRight.configID
        case "palette.terminalSplitDown":
            return CmuxSurfaceTabBarBuiltInAction.splitDown.configID
        default:
            return nil
        }
    }

    private func commandPaletteShortcutHint(
        for contribution: CommandPaletteCommandContribution,
        context: CommandPaletteContextSnapshot
    ) -> String? {
        if let configuredShortcut = cmuxConfigStore.resolvedAction(id: contribution.commandId)?.shortcut {
            return configuredShortcut.displayString
        }
        if let configuredPaletteAction = commandPaletteConfigActionID(for: contribution.commandId),
           let configuredShortcut = cmuxConfigStore.resolvedAction(id: configuredPaletteAction)?.shortcut {
            return configuredShortcut.displayString
        }
        if let action = Self.commandPaletteShortcutAction(forCommandID: contribution.commandId) {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { return nil }
            guard action.shortcutContext.isAvailable(commandPaletteContext: context) else {
                return nil
            }
            return shortcut.displayString
        }
        if let staticShortcut = commandPaletteStaticShortcutHint(for: contribution.commandId) {
            return staticShortcut
        }
        return contribution.shortcutHint
    }

    private func commandPaletteStaticShortcutHint(for commandId: String) -> String? {
        switch commandId {
        case "palette.closeTab":
            return "⌘W"
        case "palette.closeWorkspace":
            return "⌘⇧W"
        case "palette.openSettings":
            return "⌘,"
        case "palette.browserBack":
            return "⌘["
        case "palette.browserForward":
            return "⌘]"
        case "palette.browserReload":
            return "⌘R"
        case "palette.browserFocusAddressBar":
            return "⌘L"
        case "palette.browserZoomIn":
            return "⌘="
        case "palette.browserZoomOut":
            return "⌘-"
        case "palette.browserZoomReset":
            return "⌘0"
        case "palette.markdownZoomIn":
            return "⌘="
        case "palette.markdownZoomOut":
            return "⌘-"
        case "palette.markdownZoomReset":
            return "⌘0"
        case "palette.terminalFind":
            return "⌘F"
        case "palette.terminalFindNext":
            return "⌘G"
        case "palette.terminalFindPrevious":
            return "⌥⌘G"
        case "palette.terminalHideFind":
            return "⌥⌘⇧F"
        case "palette.terminalUseSelectionForFind":
            return "⌘E"
        case "palette.toggleFullScreen":
            return "\u{2303}\u{2318}F"
        default:
            return nil
        }
    }

    private func commandPaletteContextSnapshot(
        terminalOpenTargets: Set<TerminalDirectoryOpenTarget>? = nil
    ) -> CommandPaletteContextSnapshot {
        var snapshot = CommandPaletteContextSnapshot()
        snapshot.setBool(CommandPaletteContextKeys.workspaceMinimalModeEnabled, isMinimalMode)
        snapshot.setBool(CommandPaletteContextKeys.sidebarMatchTerminalBackground, sidebarMatchTerminalBackground)
        snapshot.setBool(CommandPaletteContextKeys.browserDisabled, BrowserAvailabilitySettings.isDisabled())
        if let auth = AppDelegate.shared?.auth {
            snapshot.setBool(CommandPaletteContextKeys.authSignedIn, auth.coordinator.isAuthenticated)
            snapshot.setBool(
                CommandPaletteContextKeys.authWorking,
                auth.coordinator.isLoading || auth.coordinator.isRestoringSession || auth.browserSignIn.isSigningIn
            )
        }

        if let workspace = tabManager.selectedWorkspace {
            let pinTarget = WorkspaceActionDispatcher.Target.single(workspace.id)
            let pinState = WorkspaceActionDispatcher.pinState(in: tabManager, target: pinTarget)
            snapshot.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            snapshot.setString(CommandPaletteContextKeys.workspaceName, workspaceDisplayName(workspace))
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomName, workspace.customTitle != nil)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasCustomDescription, workspace.hasCustomDescription)
            snapshot.setBool(CommandPaletteContextKeys.workspaceShouldPin, pinState?.pinned ?? !workspace.isPinned)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasPullRequests,
                !workspace.sidebarPullRequestsInDisplayOrder().isEmpty
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasSplits,
                workspace.bonsplitController.allPaneIds.count > 1
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanvasLayout,
                workspace.layoutMode == .canvas
            )
            let workspaceIndex = tabManager.tabs.firstIndex { $0.id == workspace.id }
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasPeers, tabManager.tabs.count > 1)
            snapshot.setBool(CommandPaletteContextKeys.workspaceHasAbove, (workspaceIndex ?? 0) > 0)
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceHasBelow,
                (workspaceIndex ?? tabManager.tabs.count - 1) < tabManager.tabs.count - 1
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanMarkRead,
                sidebarUnread.canMarkWorkspaceRead(forWorkspaceIds: [workspace.id])
            )
            snapshot.setBool(
                CommandPaletteContextKeys.workspaceCanMarkUnread,
                sidebarUnread.canMarkWorkspaceUnread(forWorkspaceIds: [workspace.id])
            )
        }

        if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            let panelIsRemoteTerminal = workspace.isRemoteTerminalSurface(panelId)
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(CommandPaletteContextKeys.panelName, panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle))
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            if let browserPanel = panelContext.panel as? BrowserPanel {
                snapshot.setBool(CommandPaletteContextKeys.panelBrowserFocusModeActive, browserPanel.isBrowserFocusModeActive)
            }
            // Markdown zoom only affects the rendered preview, so don't surface
            // the zoom commands when the panel is in raw text-edit mode.
            snapshot.setBool(
                CommandPaletteContextKeys.panelIsMarkdown,
                (panelContext.panel as? MarkdownPanel)?.displayMode == .preview
            )
            snapshot.setBool(
                CommandPaletteContextKeys.panelBrowserOmnibarVisible,
                (panelContext.panel as? BrowserPanel)?.isOmnibarVisible ?? true
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasPane, workspace.paneId(forPanelId: panelId) != nil)
            let fallbackForkableSnapshot = workspace.restoredAgentSnapshotsByPanelId[panelId]
            snapshot.setBool(
                CommandPaletteContextKeys.panelHasForkableAgent,
                Self.commandPalettePanelHasForkableAgent(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    fallbackSnapshot: fallbackForkableSnapshot,
                    isRemoteTerminal: panelIsRemoteTerminal
                )
            )
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            snapshot.setBool(CommandPaletteContextKeys.panelCanMoveToNewWorkspace, workspace.panels.count > 1)
            let hasUnread = workspace.manualUnreadPanelIds.contains(panelId) ||
                workspace.restoredUnreadPanelIds.contains(panelId) ||
                sidebarUnread.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: panelId)
            snapshot.setBool(CommandPaletteContextKeys.panelHasUnread, hasUnread)

            if panelIsTerminal {
                let availableTargets = terminalOpenTargets ?? TerminalDirectoryOpenTarget.availableTargets()
                for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
                    snapshot.setBool(
                        CommandPaletteContextKeys.terminalOpenTargetAvailable(target),
                        availableTargets.contains(target)
                    )
                }
            }
        }

        if case .updateAvailable = updateViewModel.effectiveState {
            snapshot.setBool(CommandPaletteContextKeys.updateHasAvailable, true)
        }

        return snapshot
    }

    /// Search keywords for the "Mobile Connect" command palette entry.
    ///
    /// Kept as a single source of truth so the contribution and its behavioral
    /// test agree on what queries (e.g. `ios`, `ipados`) must surface the
    /// command. These are platform/technical terms that read the same across
    /// locales, so they are not localized.
    static let commandPaletteMobileConnectKeywords: [String] = [
        "mobile", "connect", "pair", "pairing", "device",
        "ios", "ipados", "iphone", "ipad", "phone", "tablet", "qr",
    ]

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
            return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(name)")
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }

        func markdownPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.markdownWithName", defaultValue: "Markdown • \(name)")
        }

        func workspaceColorCommandTitle(_ paletteName: String) -> String {
            switch paletteName {
            case "Red":
                return String(localized: "shortcut.setWorkspaceColorRed.label", defaultValue: "Workspace Color: Red")
            case "Crimson":
                return String(localized: "shortcut.setWorkspaceColorCrimson.label", defaultValue: "Workspace Color: Crimson")
            case "Orange":
                return String(localized: "shortcut.setWorkspaceColorOrange.label", defaultValue: "Workspace Color: Orange")
            case "Amber":
                return String(localized: "shortcut.setWorkspaceColorAmber.label", defaultValue: "Workspace Color: Amber")
            case "Olive":
                return String(localized: "shortcut.setWorkspaceColorOlive.label", defaultValue: "Workspace Color: Olive")
            case "Green":
                return String(localized: "shortcut.setWorkspaceColorGreen.label", defaultValue: "Workspace Color: Green")
            case "Teal":
                return String(localized: "shortcut.setWorkspaceColorTeal.label", defaultValue: "Workspace Color: Teal")
            case "Aqua":
                return String(localized: "shortcut.setWorkspaceColorAqua.label", defaultValue: "Workspace Color: Aqua")
            case "Blue":
                return String(localized: "shortcut.setWorkspaceColorBlue.label", defaultValue: "Workspace Color: Blue")
            default:
                return String(
                    localized: "command.workspaceColor.named",
                    defaultValue: "Workspace Color: \(paletteName)"
                )
            }
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")),
                subtitle: constant(String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserWorkspace",
                title: constant(String(localized: "command.newBrowserWorkspace.title", defaultValue: "New Browser Workspace")),
                subtitle: constant(String(localized: "command.newBrowserWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "browser", "workspace", "web"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(String(localized: "command.newWindow.title", defaultValue: "New Window")),
                subtitle: constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window")),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'cmux' in PATH")),
                subtitle: constant(String(localized: "command.installCLI.subtitle", defaultValue: "CLI")),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'cmux' from PATH")),
                subtitle: constant(String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(String(localized: "command.openFolder.title", defaultValue: "Open Folder…")),
                subtitle: constant(String(localized: "command.openFolder.subtitle", defaultValue: "Workspace")),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolderInVSCodeInline",
                title: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.title",
                        defaultValue: "Open Folder in VS Code (Inline)…"
                    )
                ),
                subtitle: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.subtitle",
                        defaultValue: "VS Code Inline"
                    )
                ),
                keywords: ["open", "folder", "directory", "project", "vs", "code", "inline", "editor", "browser"],
                when: { _ in TerminalDirectoryOpenTarget.vscodeInline.isAvailable() }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenPreviousSession",
                title: constant(String(localized: "command.reopenPreviousSession.title", defaultValue: "Restore Previous App Launch")),
                subtitle: constant(String(localized: "command.reopenPreviousSession.subtitle", defaultValue: "History")),
                keywords: ["reopen", "restore", "previous", "session", "launch", "resume"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)")),
                subtitle: constant(String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant(String(localized: "command.newBrowserTab.title", defaultValue: "New Tab (Browser)")),
                subtitle: constant(String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(String(localized: "command.closeTab.title", defaultValue: "Close Tab")),
                subtitle: constant(String(localized: "command.closeTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace")),
                subtitle: constant(String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace")),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(String(localized: "command.closeWindow.title", defaultValue: "Close Window")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")),
                subtitle: constant(String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window")),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant(String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed")),
                subtitle: constant(String(localized: "menu.history.title", defaultValue: "History")),
                keywords: ["reopen", "closed", "recently", "history", "tab", "workspace", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(String(localized: "command.toggleLeftSidebar.title", defaultValue: "Toggle Left Sidebar")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["toggle", "sidebar", "left", "layout"]
            )
        )
        // "Sidebar: <provider>" switch commands for each available view. The
        // built-in views are always offered; `descriptors` adds the hosted
        // extension sidebar only while the experimental Extensions beta is on.
        for descriptor in CmuxExtensionSidebarSelection.descriptors {
            let title = CmuxExtensionSidebarSelection.localizedTitle(for: descriptor)
            let titleFormat = String(localized: "command.switchExtensionSidebar.title", defaultValue: "Sidebar: %@")
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: commandPaletteExtensionSidebarCommandID(descriptor.id),
                    title: constant(String.localizedStringWithFormat(titleFormat, title)),
                    subtitle: constant(String(localized: "command.switchExtensionSidebar.subtitle", defaultValue: "Choose Sidebar")),
                    keywords: ["sidebar", "switch", "extension", title.lowercased()]
                )
            )
        }
        contributions.append(contentsOf: Self.commandPaletteRightSidebarModeCommandContributions())
        contributions.append(contentsOf: Self.commandPaletteRightSidebarToolPaneCommandContributions())
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleMatchTerminalBackground",
                title: { context in
                    context.bool(CommandPaletteContextKeys.sidebarMatchTerminalBackground)
                        ? String(localized: "command.disableMatchTerminalBackground.title", defaultValue: "Disable Match Terminal Background")
                        : String(localized: "command.enableMatchTerminalBackground.title", defaultValue: "Enable Match Terminal Background")
                },
                subtitle: constant(String(localized: "command.matchTerminalBackground.subtitle", defaultValue: "Sidebar")),
                keywords: ["match", "terminal", "background", "transparency", "sidebar", "surface", "chrome"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(contentsOf: Self.commandPaletteViewCommandContributions())
        contributions.append(contentsOf: Self.commandPaletteCanvasCommandContributions())
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(String(localized: "command.showNotifications.title", defaultValue: "Show Notifications")),
                subtitle: constant(String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications")),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleUnread",
                title: constant(String(localized: "command.toggleUnread.title", defaultValue: "Toggle Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["toggle", "mark", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markOldestUnreadAndJumpNext",
                title: constant(
                    String(
                        localized: "command.markOldestUnreadAndJumpNext.title",
                        defaultValue: "Mark as Oldest Unread and Jump to Next Latest Unread"
                    )
                ),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["mark", "oldest", "unread", "jump", "next", "notification", "defer"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(String(localized: "command.openSettings.title", defaultValue: "Open Settings")),
                subtitle: constant(String(localized: "command.openSettings.subtitle", defaultValue: "Global")),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openCmuxSettingsFile",
                title: constant(String(localized: "settings.settingsJSON.openFile", defaultValue: "Open cmux.json")),
                subtitle: constant(String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json")),
                keywords: ["open", "cmux", "json", "config", "configuration", "settings", "file", "editor", "dotfile"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openGhosttySettings",
                title: constant(
                    String(
                        localized: "command.openGhosttySettings.title",
                        defaultValue: "Open Ghostty Settings in TextEdit"
                    )
                ),
                subtitle: constant(
                    String(localized: "command.openGhosttySettings.subtitle", defaultValue: "Ghostty Config Files")
                ),
                keywords: ["open", "ghostty", "settings", "config", "configuration", "file", "textedit", "terminal"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.mobileConnect",
                title: constant(String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad")),
                subtitle: constant(String(localized: "command.mobileConnect.subtitle", defaultValue: "Mobile")),
                keywords: Self.commandPaletteMobileConnectKeywords
            )
        )
        contributions.append(contentsOf: Self.commandPaletteAuthCommandContributions())
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.makeDefaultTerminal",
                title: constant(
                    String(
                        localized: "command.makeDefaultTerminal.title",
                        defaultValue: "Make cmux the Default Terminal"
                    )
                ),
                subtitle: constant(
                    String(localized: "command.makeDefaultTerminal.subtitle", defaultValue: "Global")
                ),
                keywords: String(
                    localized: "command.makeDefaultTerminal.keywords",
                    defaultValue: "default,terminal,ssh,launch,services,handler,command,tool,executable"
                )
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
                when: { !$0.bool(CommandPaletteContextKeys.defaultTerminalIsDefault) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")),
                subtitle: constant(String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global")),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)")),
                subtitle: constant(String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global")),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update")),
                subtitle: constant(String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener")),
                subtitle: constant(String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global")),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableBrowser",
                title: constant(String(localized: "command.disableBrowser.title", defaultValue: "Disable cmux Browser")),
                subtitle: constant(String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "disable", "external", "default", "open", "auth"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableBrowser",
                title: constant(String(localized: "command.enableBrowser.title", defaultValue: "Enable cmux Browser")),
                subtitle: constant(String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "enable", "embedded", "open"],
                when: { $0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(contentsOf: Self.commandPaletteSettingsToggleCommandContributions())

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant(String(localized: "command.renameWorkspace.title", defaultValue: "Rename Workspace…")),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.editWorkspaceDescription",
                title: constant(String(localized: "command.editWorkspaceDescription.title", defaultValue: "Edit Workspace Description…")),
                subtitle: workspaceSubtitle,
                keywords: ["edit", "workspace", "description", "notes", "markdown"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant(String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceDescription",
                title: constant(String(localized: "command.clearWorkspaceDescription.title", defaultValue: "Clear Workspace Description")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "description", "notes"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomDescription)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? String(localized: "command.pinWorkspace.title", defaultValue: "Pin Workspace") : String(localized: "command.unpinWorkspace.title", defaultValue: "Unpin Workspace")
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.resetWorkspaceColor",
                title: constant(String(localized: "shortcut.resetWorkspaceColor.label", defaultValue: "Reset Workspace Color")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "color", "reset", "clear", "palette"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        for entry in WorkspaceTabColorSettings.palette() {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: commandPaletteWorkspaceColorCommandID(entry.name),
                    title: constant(workspaceColorCommandTitle(entry.name)),
                    subtitle: workspaceSubtitle,
                    keywords: ["workspace", "color", "palette", entry.name.lowercased()],
                    when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant(String(localized: "command.nextWorkspace.title", defaultValue: "Next Workspace")),
                subtitle: constant(String(localized: "command.nextWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant(String(localized: "command.previousWorkspace.title", defaultValue: "Previous Workspace")),
                subtitle: constant(String(localized: "command.previousWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceUp",
                title: constant(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "up", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceDown",
                title: constant(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "down", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceToTop",
                title: constant(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "top", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeOtherWorkspaces",
                title: constant(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "other", "workspaces", "reset", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasPeers) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesBelow",
                title: constant(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "below", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesAbove",
                title: constant(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "above", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceRead",
                title: constant(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "read", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanMarkRead) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceUnread",
                title: constant(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "unread", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceCanMarkUnread) }
            )
        )
        appendIdentifierCopyCommandContributions(
            to: &contributions,
            workspaceSubtitle: workspaceSubtitle,
            panelSubtitle: panelSubtitle
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant(String(localized: "command.renameTab.title", defaultValue: "Rename Tab…")),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant(String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name")),
                subtitle: panelSubtitle,
                keywords: ["clear", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        appendMoveTabToNewWorkspaceCommandContribution(to: &contributions, panelSubtitle: panelSubtitle)
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? String(localized: "command.pinTab.title", defaultValue: "Pin Tab") : String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read") : String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(String(localized: "command.nextTabInPane.title", defaultValue: "Next Tab in Pane")),
                subtitle: constant(String(localized: "command.nextTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(String(localized: "command.previousTabInPane.title", defaultValue: "Previous Tab in Pane")),
                subtitle: constant(String(localized: "command.previousTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant(String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links")),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    $0.bool(CommandPaletteContextKeys.workspaceHasPullRequests)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openDiffViewer",
                title: constant(String(localized: "command.openDiffViewer.title", defaultValue: "Open Diff Viewer")),
                subtitle: workspaceSubtitle,
                keywords: ["diff", "changes", "git", "review", "branch", "unstaged", "codeview", "agent", "codex", "claude"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openDirectoryDiffViewer",
                title: constant(String(localized: "command.openDirectoryDiffViewer.title", defaultValue: "Open Directory Diff Viewer")),
                subtitle: workspaceSubtitle,
                keywords: ["diff", "changes", "git", "review", "branch", "unstaged", "codeview", "directory", "cwd", "folder"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserBack",
                title: constant(String(localized: "command.browserBack.title", defaultValue: "Back")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant(String(localized: "command.browserForward.title", defaultValue: "Forward")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant(String(localized: "command.browserReload.title", defaultValue: "Reload Page")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant(String(localized: "command.browserOpenDefault.title", defaultValue: "Open Current Page in Default Browser")),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant(String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusMode",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelBrowserFocusModeActive)
                        ? String(localized: "command.browserFocusMode.exit.title", defaultValue: "Exit Browser Focus Mode")
                        : String(localized: "command.browserFocusMode.enter.title", defaultValue: "Enter Browser Focus Mode")
                },
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "focus", "mode", "keyboard", "shortcuts", "webview"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleOmnibar",
                title: { context in
                    if context.bool(CommandPaletteContextKeys.panelBrowserOmnibarVisible) {
                        return String(localized: "command.browserHideOmnibar.title", defaultValue: "Hide Browser Omnibar")
                    }
                    return String(localized: "command.browserShowOmnibar.title", defaultValue: "Show Browser Omnibar")
                },
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "address", "omnibar", "url", "toolbar", "chrome", "show", "hide"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant(String(localized: "command.browserToggleDevTools.title", defaultValue: "Toggle Developer Tools")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant(String(localized: "command.browserConsole.title", defaultValue: "Show JavaScript Console")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReactGrab",
                title: constant(String(localized: "command.browserReactGrab.title", defaultValue: "Toggle React Grab")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "react", "grab", "inspect", "element"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant(String(localized: "command.browserZoomIn.title", defaultValue: "Zoom In")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant(String(localized: "command.browserZoomOut.title", defaultValue: "Zoom Out")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant(String(localized: "command.browserZoomReset.title", defaultValue: "Actual Size")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markdownZoomIn",
                title: constant(String(localized: "command.markdownZoomIn.title", defaultValue: "Zoom In")),
                subtitle: markdownPanelSubtitle,
                keywords: ["markdown", "zoom", "in", "font", "size", "bigger", "larger"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsMarkdown) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markdownZoomOut",
                title: constant(String(localized: "command.markdownZoomOut.title", defaultValue: "Zoom Out")),
                subtitle: markdownPanelSubtitle,
                keywords: ["markdown", "zoom", "out", "font", "size", "smaller"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsMarkdown) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markdownZoomReset",
                title: constant(String(localized: "command.markdownZoomReset.title", defaultValue: "Actual Size")),
                subtitle: markdownPanelSubtitle,
                keywords: ["markdown", "zoom", "reset", "actual size", "font", "default"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsMarkdown) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant(String(localized: "command.browserClearHistory.title", defaultValue: "Clear Browser History")),
                subtitle: constant(String(localized: "command.browserClearHistory.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant(String(localized: "command.browserSplitRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.browserSplitRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "right"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsBrowser) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant(String(localized: "command.browserSplitDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.browserSplitDown.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "down"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsBrowser) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant(String(localized: "command.browserDuplicateRight.title", defaultValue: "Duplicate Browser to the Right")),
                subtitle: constant(String(localized: "command.browserDuplicateRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "duplicate", "clone", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsBrowser) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebStop",
                title: constant(String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebRestart",
                title: constant(String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.findInDirectory",
                title: constant(String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…")),
                subtitle: constant(String(localized: "command.findInDirectory.subtitle", defaultValue: "Right Sidebar")),
                keywords: ["files", "directory", "find", "search"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(String(localized: "command.terminalFind.title", defaultValue: "Find…")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(String(localized: "command.terminalFindNext.title", defaultValue: "Find Next")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalToggleTextBoxInput",
                title: constant(String(localized: "command.terminalToggleTextBoxInput.title", defaultValue: "Toggle TextBox Input")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "prompt"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFocusTextBoxInput",
                title: constant(String(localized: "command.terminalFocusTextBoxInput.title", defaultValue: "Focus TextBox Input")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "prompt", "focus"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalAttachTextBoxFile",
                title: constant(String(localized: "command.terminalAttachTextBoxFile.title", defaultValue: "Attach File to TextBox Input")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "attach", "file", "image"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSendCtrlF",
                title: constant(String(localized: "command.terminalSendCtrlF.title", defaultValue: "Send Ctrl-F to Terminal")),
                subtitle: terminalPanelSubtitle,
                keywords: [
                    "terminal", "ctrl", "control", "f", "send", "key", "passthrough",
                    "force", "stop", "agent", "agents", "claude", "code", "hung", "background", "watchdog", "kill",
                ],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalClearScreenKeepScrollback",
                title: constant(String(localized: "command.terminalClearScreenKeepScrollback.title", defaultValue: "Clear Screen (Keep Scrollback)")),
                subtitle: terminalPanelSubtitle,
                keywords: [
                    "terminal", "clear", "screen", "scrollback", "history", "keep",
                    "preserve", "reset", "wipe", "cls", "erase",
                ],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")),
                subtitle: constant(String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationRight",
                title: constant(String(localized: "command.forkAgentConversationRight.title", defaultValue: "Fork Conversation to the Right")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "right", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationLeft",
                title: constant(String(localized: "command.forkAgentConversationLeft.title", defaultValue: "Fork Conversation to the Left")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "left", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationTop",
                title: constant(String(localized: "command.forkAgentConversationTop.title", defaultValue: "Fork Conversation to the Top")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "top", "up", "above", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationBottom",
                title: constant(String(localized: "command.forkAgentConversationBottom.title", defaultValue: "Fork Conversation to the Bottom")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "bottom", "down", "below", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationNewTab",
                title: constant(String(localized: "command.forkAgentConversationNewTab.title", defaultValue: "Fork Conversation to New Tab")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "new", "tab", "same", "pane"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationNewWorkspace",
                title: constant(String(localized: "command.forkAgentConversationNewWorkspace.title", defaultValue: "Fork Conversation to New Workspace")),
                subtitle: workspaceSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "new", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")),
                subtitle: constant(String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant(String(localized: "command.terminalSplitBrowserRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "right"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant(String(localized: "command.terminalSplitBrowserDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "down"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )

        let cmuxConfigDefaultSubtitle = String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json")
        for issue in cmuxConfigStore.configurationIssues {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: commandPaletteCmuxConfigIssueCommandID(issue),
                    title: constant(commandPaletteCmuxConfigIssueTitle(issue)),
                    subtitle: constant(commandPaletteCmuxConfigIssueSubtitle(issue)),
                    keywords: ["cmux", "config", "json", "schema", "error", "warning"]
                )
            )
        }
        for action in cmuxConfigStore.paletteCustomActions() {
            let actionTitle = sanitizeCmuxConfigPaletteText(action.title)
            let subtitleText = action.subtitle
                .map { sanitizeCmuxConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? cmuxConfigDefaultSubtitle
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: action.id,
                    title: constant(actionTitle),
                    subtitle: constant(subtitleText),
                    keywords: action.keywords
                )
            )
        }

        return contributions
    }

    private func sanitizeCmuxConfigPaletteText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commandPaletteCmuxConfigIssueCommandID(_ issue: CmuxConfigIssue) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in issue.id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.cmuxConfig.issue.\(String(hash, radix: 16))"
    }

    private func commandPaletteWorkspaceColorCommandID(_ colorName: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in colorName.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.workspaceColor.\(String(hash, radix: 16))"
    }

    private func commandPaletteExtensionSidebarCommandID(_ providerId: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in providerId.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.extensionSidebar.\(String(hash, radix: 16))"
    }

    private func commandPaletteCmuxConfigIssueTitle(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            return String(
                localized: "command.cmuxConfig.issue.schemaError.title",
                defaultValue: "cmux.json Schema Error"
            )
        default:
            return String(
                localized: "command.cmuxConfig.issue.warning.title",
                defaultValue: "cmux.json Configuration Warning"
            )
        }
    }

    private func commandPaletteCmuxConfigIssueSubtitle(_ issue: CmuxConfigIssue) -> String {
        let rawPath = issue.sourcePath.map {
            NSString(string: $0).abbreviatingWithTildeInPath
        } ?? issue.settingName
        let path = sanitizeCmuxConfigPaletteText(rawPath)
        let detail = sanitizeCmuxConfigPaletteText(commandPaletteCmuxConfigIssueDetail(issue))
        guard !detail.isEmpty else { return path }
        let format = String(
            localized: "command.cmuxConfig.issue.subtitle",
            defaultValue: "%@: %@"
        )
        return String(format: format, path, detail)
    }

    private func commandPaletteCmuxConfigIssueDetail(_ issue: CmuxConfigIssue) -> String {
        switch issue.kind {
        case .schemaError:
            let format = String(
                localized: "command.cmuxConfig.issue.schemaError.detail",
                defaultValue: "%@"
            )
            let fallback = String(
                localized: "command.cmuxConfig.issue.schemaError.fallback",
                defaultValue: "Invalid cmux.json"
            )
            return String(format: format, issue.message ?? fallback)
        case .newWorkspaceActionNotFound:
            let format = String(localized: "command.cmuxConfig.issue.newWorkspaceActionNotFound.detail", defaultValue: "%@ references missing action '%@'")
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandNotFound:
            let format = String(
                localized: "command.cmuxConfig.issue.newWorkspaceCommandNotFound.detail",
                defaultValue: "%@ references missing command '%@'"
            )
            return String(format: format, issue.settingName, issue.commandName ?? "")
        case .newWorkspaceCommandRequiresWorkspace:
            let format = String(
                localized: "command.cmuxConfig.issue.newWorkspaceCommandRequiresWorkspace.detail",
                defaultValue: "%@ '%@' must reference a workspace command"
            )
            return String(format: format, issue.settingName, issue.commandName ?? "")
        }
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            AppDelegate.shared?.performNewWorkspaceAction(
                tabManager: tabManager,
                debugSource: "palette.newWorkspace"
            )
        }
        registry.register(commandId: "palette.newBrowserWorkspace") {
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.performNewBrowserWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "palette.newBrowserWorkspace"
                )
            }
        }
        registry.register(commandId: "palette.openFolder") {
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                panel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
            }
        }
        registry.register(commandId: "palette.openFolderInVSCodeInline") {
            DispatchQueue.main.async {
                AppDelegate.shared?.showOpenFolderInInlineVSCodePanel(tabManager: tabManager)
            }
        }
        registry.register(commandId: "palette.reopenPreviousSession") {
            if AppDelegate.shared?.reopenPreviousSession() != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.newWindow") {
            guard let appDelegate = AppDelegate.shared else { return }
            appDelegate.openNewMainWindow(preferredWindow: appDelegate.mainWindow(for: windowId))
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallCmuxCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newTerminal.configID) {
                tabManager.newSurface()
            }
        }
        registry.register(commandId: "palette.newBrowserTab") {
            if executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newBrowser.configID) {
                return
            }
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
            }
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            if let appDelegate = AppDelegate.shared {
                appDelegate.closeWindowWithConfirmation(window)
            } else {
                window.performClose(nil)
            }
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            if let appDelegate = AppDelegate.shared {
                _ = appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: tabManager)
            } else {
                _ = tabManager.reopenMostRecentlyClosedItem()
            }
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        // Register a handler for every possible view (including the hosted
        // extension sidebar) regardless of the beta flag, so a contribution that
        // was visible when the flag was on still resolves after a runtime flip.
        // Visibility is gated by `descriptors`; the handler set is the superset.
        for descriptor in CmuxExtensionSidebarSelection.allDescriptors {
            registry.register(commandId: commandPaletteExtensionSidebarCommandID(descriptor.id)) {
                CmuxExtensionSidebarSelection.setProviderId(descriptor.id)
            }
        }
        for mode in RightSidebarMode.allCases {
            registry.register(commandId: Self.commandPaletteRightSidebarModeCommandID(mode)) {
                handleCommandPaletteRightSidebarMode(mode, observedWindow: observedWindow)
            }
        }
        for descriptor in Self.commandPaletteRightSidebarToolPaneCommandDescriptors() {
            registry.register(commandId: descriptor.commandId) {
                handleCommandPaletteRightSidebarToolPane(descriptor.mode)
            }
        }
        registry.register(commandId: "palette.toggleMatchTerminalBackground") {
            sidebarMatchTerminalBackground.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registerViewCommandHandlers(&registry)
        registerCanvasCommandHandlers(&registry)
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.toggleUnread") {
            AppDelegate.shared?.toggleFocusedNotificationUnread(
                preferredWindow: observedWindow
            )
        }
        registry.register(commandId: "palette.markOldestUnreadAndJumpNext") {
            AppDelegate.shared?.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: observedWindow
            )
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            cmuxDebugLog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                cmuxDebugLog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.openCmuxSettingsFile") {
#if DEBUG
            cmuxDebugLog("palette.openCmuxSettingsFile.invoke")
#endif
            openCmuxSettingsFileInEditor()
        }
        registry.register(commandId: "palette.openGhosttySettings") {
#if DEBUG
            cmuxDebugLog("palette.openGhosttySettings.invoke")
#endif
            GhosttyApp.shared.openConfigurationInTextEdit()
        }
        registry.register(commandId: "palette.mobileConnect") {
#if DEBUG
            cmuxDebugLog("palette.mobileConnect.invoke")
#endif
            MobilePairingWindowController.shared.show()
        }
        registerAuthCommandHandlers(&registry)
        registry.register(commandId: "palette.makeDefaultTerminal") {
            DefaultTerminalUserAction.setAsDefault(debugSource: "palette.makeDefaultTerminal")
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }
        registry.register(commandId: "palette.disableBrowser") {
            BrowserAvailabilitySettings.setDisabled(true)
        }
        registry.register(commandId: "palette.enableBrowser") {
            BrowserAvailabilitySettings.setDisabled(false)
        }
        registerSettingsToggleCommandHandlers(&registry)

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.editWorkspaceDescription") {
            beginWorkspaceDescriptionFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.clearWorkspaceDescription") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomDescription(tabId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            let pinTarget = WorkspaceActionDispatcher.Target.single(workspace.id)
            guard WorkspaceActionDispatcher.performPinAction(in: tabManager, target: pinTarget) != nil else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: "palette.resetWorkspaceColor") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.applyWorkspaceColor(nil, toWorkspaceIds: [workspace.id])
        }
        for entry in WorkspaceTabColorSettings.palette() {
            registry.register(commandId: commandPaletteWorkspaceColorCommandID(entry.name)) {
                guard let workspace = tabManager.selectedWorkspace else {
                    NSSound.beep()
                    return
                }
                tabManager.applyWorkspacePaletteColor(named: entry.name, toWorkspaceIds: [workspace.id])
            }
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }
        registry.register(commandId: "palette.moveWorkspaceUp") {
            moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        registry.register(commandId: "palette.closeOtherWorkspaces") {
            closeOtherSelectedWorkspaces()
        }
        registry.register(commandId: "palette.closeWorkspacesBelow") {
            closeSelectedWorkspacesBelow()
        }
        registry.register(commandId: "palette.closeWorkspacesAbove") {
            closeSelectedWorkspacesAbove()
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forTabId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forTabId: workspaceId)
        }
        registerIdentifierCopyCommandHandlers(&registry)

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.moveTabToNewWorkspace") {
            guard moveFocusedPanelToNewWorkspace() else { NSSound.beep(); return }
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId) ||
                panelContext.workspace.restoredUnreadPanelIds.contains(panelContext.panelId) ||
                sidebarUnread.hasUnreadNotification(forWorkspaceId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequestsInConfiguredBrowser() {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.openDiffViewer") {
            if AppDelegate.shared?.openDiffViewerForFocusedWorkspace(for: tabManager) != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.openDirectoryDiffViewer") {
            if AppDelegate.shared?.openDirectoryDiffViewerForFocusedWorkspace(for: tabManager) != true {
                NSSound.beep()
            }
        }

        registry.register(commandId: "palette.browserBack") {
            tabManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            tabManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            tabManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusMode") {
            if !tabManager.toggleBrowserFocusModeForFocusedBrowser(reason: "commandPalette") {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleOmnibar") {
            if !tabManager.toggleOmnibarFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !tabManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !tabManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserReactGrab") {
            if !tabManager.toggleReactGrabFromCurrentFocus() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !tabManager.zoomInFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !tabManager.zoomOutFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !tabManager.resetZoomFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomIn") {
            if !tabManager.zoomInFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomOut") {
            if !tabManager.zoomOutFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.markdownZoomReset") {
            if !tabManager.resetZoomFocusedMarkdown() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            BrowserHistoryStore.shared.clearHistory()
        }
        registry.register(commandId: "palette.findInDirectory") {
            _ = AppDelegate.shared?.focusFileSearchInActiveMainWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = tabManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.vscodeServeWebStop") {
            stopInlineVSCodeServeWeb()
        }
        registry.register(commandId: "palette.vscodeServeWebRestart") {
            if !restartInlineVSCodeServeWeb() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalToggleTextBoxInput") {
            if !tabManager.toggleFocusedTerminalTextBox() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFocusTextBoxInput") {
            if !tabManager.focusFocusedTerminalTextBoxInputOrTerminal() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalAttachTextBoxFile") {
            if !tabManager.attachFileToFocusedTerminalTextBoxInput() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSendCtrlF") {
            if !tabManager.sendCtrlFToFocusedTerminal() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalClearScreenKeepScrollback") {
            if !tabManager.clearFocusedTerminalKeepingScrollback() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.splitRight.configID) {
                tabManager.createSplit(direction: .right)
            }
        }
        registry.register(commandId: "palette.forkAgentConversationRight") {
            forkFocusedAgentConversationRight()
        }
        registry.register(commandId: "palette.forkAgentConversationLeft") {
            forkFocusedAgentConversationLeft()
        }
        registry.register(commandId: "palette.forkAgentConversationTop") {
            forkFocusedAgentConversationTop()
        }
        registry.register(commandId: "palette.forkAgentConversationBottom") {
            forkFocusedAgentConversationBottom()
        }
        registry.register(commandId: "palette.forkAgentConversationNewTab") {
            forkFocusedAgentConversationToNewTab()
        }
        registry.register(commandId: "palette.forkAgentConversationNewWorkspace") {
            forkFocusedAgentConversationToNewWorkspace()
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.splitDown.configID) {
                tabManager.createSplit(direction: .down)
            }
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !tabManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            if let workspace = tabManager.selectedWorkspace, !tabManager.equalizeSplits(tabId: workspace.id) {
#if DEBUG
                cmuxDebugLog("palette.equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
#endif
            }
        }

        for issue in cmuxConfigStore.configurationIssues {
            let captured = issue
            registry.register(commandId: commandPaletteCmuxConfigIssueCommandID(issue)) {
                openCmuxConfigIssue(captured)
            }
        }
        for action in cmuxConfigStore.paletteCustomActions() {
            let captured = action
            registry.register(commandId: action.id) {
                executeConfiguredAction(captured)
            }
        }
    }

    private func openCmuxConfigIssue(_ issue: CmuxConfigIssue) {
        guard let sourcePath = issue.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath) else {
            NSSound.beep()
            return
        }
        PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: sourcePath))
    }

    @discardableResult
    private func executeConfiguredAction(id: String) -> Bool {
        guard let action = cmuxConfigStore.resolvedAction(id: id) else {
            return false
        }
        return executeConfiguredAction(action)
    }

    @discardableResult
    private func executeConfiguredAction(_ action: CmuxResolvedConfigAction) -> Bool {
        let baseCwd = configuredActionBaseCwd()
        return CmuxConfigExecutor.execute(
            action: action,
            commands: cmuxConfigStore.loadedCommands,
            commandSourcePaths: cmuxConfigStore.commandSourcePaths,
            tabManager: tabManager,
            baseCwd: baseCwd,
            globalConfigPath: cmuxConfigStore.globalConfigPath
        )
    }

    private func configuredActionBaseCwd() -> String {
        tabManager.selectedWorkspace?.resolvedWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    private static func commandPaletteWorkspaceDisplayName(_ workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : title
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        Self.commandPaletteWorkspaceDisplayName(workspace)
    }

    private func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Tab") : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    static func commandPaletteResolvedSelectionIndex(
        preferredCommandID: String?,
        fallbackSelectedIndex: Int,
        resultIDs: [String]
    ) -> Int {
        guard !resultIDs.isEmpty else { return 0 }
        if let preferredCommandID,
           let anchoredIndex = resultIDs.firstIndex(of: preferredCommandID) {
            return anchoredIndex
        }
        return min(max(fallbackSelectedIndex, 0), resultIDs.count - 1)
    }

    static func commandPaletteSelectionAnchorCommandID(
        selectedIndex: Int,
        resultIDs: [String]
    ) -> String? {
        guard !resultIDs.isEmpty else { return nil }
        let resolvedIndex = min(max(selectedIndex, 0), resultIDs.count - 1)
        return resultIDs[resolvedIndex]
    }

    static func commandPalettePendingActivationRequestID(
        _ pendingActivation: CommandPalettePendingActivation?
    ) -> UInt64? {
        switch pendingActivation {
        case .selected(let requestID, _, _):
            return requestID
        case .command(let requestID, _):
            return requestID
        case nil:
            return nil
        }
    }

    static func commandPalettePendingActivation(
        _ pendingActivation: CommandPalettePendingActivation?,
        rebasedTo requestID: UInt64
    ) -> CommandPalettePendingActivation? {
        switch pendingActivation {
        case .selected(_, let fallbackSelectedIndex, let preferredCommandID):
            return .selected(
                requestID: requestID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                preferredCommandID: preferredCommandID
            )
        case .command(_, let commandID):
            return .command(requestID: requestID, commandID: commandID)
        case nil:
            return nil
        }
    }

    static func commandPaletteResolvedPendingActivation(
        _ pendingActivation: CommandPalettePendingActivation?,
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPaletteResolvedActivation? {
        switch pendingActivation {
        case .selected(let activationRequestID, let fallbackSelectedIndex, let preferredCommandID):
            guard activationRequestID == requestID else { return nil }
            let resolvedIndex = commandPaletteResolvedSelectionIndex(
                preferredCommandID: preferredCommandID,
                fallbackSelectedIndex: fallbackSelectedIndex,
                resultIDs: resultIDs
            )
            return .selected(index: resolvedIndex)
        case .command(let activationRequestID, let commandID):
            guard activationRequestID == requestID, resultIDs.contains(commandID) else { return nil }
            return .command(commandID: commandID)
        case nil:
            return nil
        }
    }

    static func commandPalettePendingActivationResolution(
        _ pendingActivation: CommandPalettePendingActivation?,
        requestID: UInt64,
        resultIDs: [String]
    ) -> CommandPalettePendingActivationResolutionResult {
        CommandPalettePendingActivationResolutionResult(
            resolvedActivation: commandPaletteResolvedPendingActivation(
                pendingActivation,
                requestID: requestID,
                resultIDs: resultIDs
            ),
            shouldClearPendingActivation: commandPalettePendingActivationRequestID(pendingActivation) == requestID
        )
    }

    static func commandPaletteScrollPositionAnchor(
        selectedIndex: Int,
        resultCount: Int
    ) -> UnitPoint? {
        guard resultCount > 0 else { return nil }
        if selectedIndex <= 0 { return UnitPoint.top }
        if selectedIndex >= resultCount - 1 { return UnitPoint.bottom }
        return nil
    }

    private func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        guard resultCount > 0 else {
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            commandPaletteScrollTargetIndex = selectedIndex
        }
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                assignTarget()
            }
        } else {
            assignTarget()
        }
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteSelectionAnchorCommandID = Self.commandPaletteSelectionAnchorCommandID(
            selectedIndex: commandPaletteSelectedResultIndex,
            resultIDs: resultIDs
        )
    }

    private func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: cachedCommandPaletteResults.map(\.id))
    }

    private func syncCommandPaletteSelectionAnchorFromVisibleResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: commandPaletteVisibleResults.map(\.id))
    }

    private func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteVisibleResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        if commandPaletteHasCurrentResolvedResults {
            syncCommandPaletteSelectionAnchorFromCurrentResults()
        } else {
            syncCommandPaletteSelectionAnchorFromVisibleResults()
        }
        updateCommandPaletteScrollTarget(resultCount: count, animated: true)
        syncCommandPaletteOverlayCommandListState()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func forwardCommandPaletteUnhandledNavigationKeyToFocusedTerminal(_ event: NSEvent) -> Bool {
        guard let target = commandPaletteRestoreFocusTarget,
              target.intent == .terminal(.surface),
              let workspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }),
              let terminalPanel = workspace.panels[target.panelId] as? TerminalPanel else { return false }
        terminalPanel.hostedView.forwardKeyDownToSurface(event); return true
    }

    static func commandPaletteShouldPopRenameInputOnDelete(
        renameDraft: String,
        modifiers: EventModifiers
    ) -> Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }

    private func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteRenameDraft = editor.string
        } else if !commandPaletteRenameDraft.isEmpty {
            commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private var commandPaletteHasCurrentResolvedResults: Bool {
        !isCommandPaletteSearchPending && commandPaletteResolvedSearchRequestID == commandPaletteSearchRequestID
    }

    private var commandPaletteShouldShowEmptyState: Bool {
        guard commandPaletteVisibleResults.isEmpty else { return false }
        if commandPaletteHasCurrentResolvedResults {
            return true
        }

        return CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: isCommandPaletteSearchPending,
            visibleResultsScopeMatches: commandPaletteVisibleResultsScope == commandPaletteListScope,
            resolvedSearchScopeMatches: commandPaletteResolvedSearchScope == commandPaletteListScope,
            resolvedSearchFingerprintMatches: commandPaletteResolvedSearchFingerprint == commandPaletteVisibleResultsFingerprint,
            resolvedResultsAreEmpty: cachedCommandPaletteResults.isEmpty
        )
    }

    private func runCommandPaletteResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        switch activation {
        case .command(let commandID):
            guard let command = cachedCommandPaletteResults.first(where: { $0.id == commandID })?.command else {
                return
            }
            runCommandPaletteCommand(command)
        case .selected(let fallbackIndex):
            guard !cachedCommandPaletteResults.isEmpty else {
                NSSound.beep()
                return
            }
            let resolvedIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: fallbackIndex,
                resultIDs: cachedCommandPaletteResults.map(\.id)
            )
            commandPaletteSelectedResultIndex = resolvedIndex
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            runCommandPaletteCommand(cachedCommandPaletteResults[resolvedIndex].command)
        }
    }

    private func runCommandPaletteResult(commandID: String) {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .command(
                    requestID: commandPaletteSearchRequestID,
                    commandID: commandID
                )
            }
            return
        }
        runCommandPaletteResolvedActivation(.command(commandID: commandID))
    }

    private func runSelectedCommandPaletteResult() {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .selected(
                    requestID: commandPaletteSearchRequestID,
                    fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                    preferredCommandID: commandPaletteSelectionAnchorCommandID
                )
            }
            return
        }

        runCommandPaletteResolvedActivation(.selected(index: commandPaletteSelectedResultIndex))
    }

    private func handleCommandPaletteSubmitRequest() {
        switch commandPaletteMode {
        case .commands:
            runSelectedCommandPaletteResult()
        case .renameInput(let target):
            continueRenameFlow(target: target)
        case .renameConfirm(let target, let proposedName):
            applyRenameFlow(target: target, proposedName: proposedName)
        case .workspaceDescriptionInput(let target):
#if DEBUG
            let newlineCount = commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "palette.wsDescription.submit.request workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
            applyWorkspaceDescriptionFlow(
                target: target,
                proposedDescription: commandPaletteWorkspaceDescriptionDraft
            )
        }
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
#if DEBUG
        cmuxDebugLog("palette.run commandId=\(command.id) dismissOnRun=\(command.dismissOnRun ? 1 : 0)")
#endif
        let postRunFocusTarget = commandPalettePostRunFocusTarget(for: command)
        recordCommandPaletteUsage(command.id)
        if command.dismissOnRun,
           Self.commandPaletteShouldDismissBeforeRun(forCommandId: command.id) {
            if let postRunFocusTarget {
                dismissCommandPalette(restoreFocus: true, preferredFocusTarget: postRunFocusTarget)
            } else {
                dismissCommandPalette(restoreFocus: false)
            }
            command.action()
            return
        }
        command.action()
        if command.dismissOnRun {
            if let postRunFocusTarget {
                dismissCommandPalette(restoreFocus: true, preferredFocusTarget: postRunFocusTarget)
            } else {
                dismissCommandPalette(restoreFocus: false)
            }
        }
    }

    private func commandPalettePostRunFocusTarget(for command: CommandPaletteCommand) -> CommandPaletteRestoreFocusTarget? {
        guard let intent = Self.commandPalettePostRunRestoreFocusIntent(forCommandId: command.id),
              let panelContext = focusedPanelContext else {
            return nil
        }
        return CommandPaletteRestoreFocusTarget(
            workspaceId: panelContext.workspace.id,
            panelId: panelContext.panelId,
            intent: intent
        )
    }

    private func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
    }

    private func openCommandPaletteCommands() {
        handleCommandPaletteListRequest(scope: .commands)
    }

    private func openCommandPaletteSwitcher() {
        handleCommandPaletteListRequest(scope: .switcher)
    }

    private func handleCommandPaletteListRequest(scope: CommandPaletteListScope) {
        let initialQuery = (scope == .commands) ? Self.commandPaletteCommandsPrefix : ""
        guard isCommandPalettePresented else {
            presentCommandPalette(initialQuery: initialQuery)
            return
        }

        if case .commands = commandPaletteMode,
           commandPaletteListScope == scope {
            dismissCommandPalette()
            return
        }

        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func openCommandPaletteRenameTabInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameTabFlow()
    }

    private func openCommandPaletteRenameWorkspaceInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameWorkspaceFlow()
    }

    private func openCommandPaletteWorkspaceDescriptionInput() {
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.open begin presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
        )
#endif
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginWorkspaceDescriptionFlow()
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.open end presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
    }

    private func presentFeedbackComposer() {
        DispatchQueue.main.async {
            isFeedbackComposerPresented = true
        }
    }

    static func shouldHandleCommandPaletteRequest(
        observedWindow: NSWindow?,
        requestedWindow: NSWindow?,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> Bool {
        guard let observedWindow else { return false }
        if let requestedWindow {
            return requestedWindow === observedWindow
        }
        if let keyWindow {
            return keyWindow === observedWindow
        }
        if let mainWindow {
            return mainWindow === observedWindow
        }
        return false
    }

    static func shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss(
        focusedPanelIsBrowser: Bool,
        focusedBrowserAddressBarPanelId: UUID?,
        focusedPanelId: UUID?
    ) -> Bool {
        focusedPanelIsBrowser && focusedBrowserAddressBarPanelId == focusedPanelId
    }

    static func commandPaletteShouldDismissBeforeRun(forCommandId commandId: String) -> Bool {
        switch commandId {
        case "palette.forkAgentConversationRight",
             "palette.forkAgentConversationLeft",
             "palette.forkAgentConversationTop",
             "palette.forkAgentConversationBottom",
             "palette.forkAgentConversationNewTab",
             "palette.forkAgentConversationNewWorkspace",
             // Entering browser focus mode focuses the web view synchronously;
             // dismiss the palette first so its makeFirstResponder(nil) doesn't
             // clear that focus and leave focus mode active without key routing.
             "palette.browserFocusMode":
            return true
        default:
            return false
        }
    }

    static func commandPalettePostRunRestoreFocusIntent(forCommandId commandId: String) -> PanelFocusIntent? {
        switch commandId {
        case "palette.terminalFocusTextBoxInput",
             "palette.terminalAttachTextBoxFile":
            return .terminal(.textBoxInput)
        default:
            return nil
        }
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteVisibleResults.count
        let selectedIndex = isCommandPalettePresented ? commandPaletteSelectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(commandPaletteDebugSnapshot(), for: window)
    }

    private func commandPaletteDebugSnapshot() -> CommandPaletteDebugSnapshot {
        guard isCommandPalettePresented else { return .empty }

        let mode: String
        switch commandPaletteMode {
        case .commands:
            mode = commandPaletteListScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .renameConfirm:
            mode = "rename_confirm"
        case .workspaceDescriptionInput:
            mode = "workspace_description_input"
        }

        let rows = Array(commandPaletteVisibleResults.prefix(20)).map { result in
                CommandPaletteDebugResultRow(
                    commandId: result.command.id,
                    title: result.command.title,
                    shortcutHint: result.command.shortcutHint,
                    trailingLabel: commandPaletteRenderTrailingLabel(for: result.command)?.text,
                    score: result.score
                )
        }

        return CommandPaletteDebugSnapshot(
            query: commandPaletteQueryForMatching,
            mode: mode,
            results: rows
        )
    }

    private func presentCommandPalette(initialQuery: String) {
        refreshCachedDefaultTerminalStatus(refreshSearchCorpusIfPresented: false)
        if let panelContext = focusedPanelContext {
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: panelContext.panel.captureFocusIntent(in: observedWindow)
            )
        } else {
            commandPaletteRestoreFocusTarget = nil
        }
        isCommandPalettePresented = true
        commandPaletteForkableAgentActivePanelKey = nil
        refreshCommandPaletteUsageHistory()
        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteMode = .commands
        commandPaletteQuery = initialQuery
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true)
        syncCommandPaletteOverlayCommandListState()
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        dismissCommandPalette(restoreFocus: restoreFocus, preferredFocusTarget: nil)
    }

    private func dismissCommandPalette(
        restoreFocus: Bool,
        preferredFocusTarget: CommandPaletteRestoreFocusTarget?
    ) {
        let focusTarget = preferredFocusTarget ?? commandPaletteRestoreFocusTarget
#if DEBUG
        if case .workspaceDescriptionInput(let target) = commandPaletteMode {
            let newlineCount = commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "palette.wsDescription.dismiss workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "restoreFocus=\(restoreFocus ? 1 : 0) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
            )
        }
#endif
        cancelCommandPaletteSearch()
        cancelCommandPaletteSearchIndexBuild()
        cancelCommandPaletteForkableAgentAvailabilityProbe()
        commandPaletteForkableAgentActivePanelKey = nil
        commandPaletteSearchRequestID &+= 1
        isCommandPalettePresented = false
        commandPaletteMode = .commands
        commandPaletteQuery = ""
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        commandPaletteRestoreFocusTarget = nil
        commandPaletteSearchCorpus = []
        commandPaletteSearchCorpusByID = [:]
        commandPaletteSearchCommandsByID = [:]
        commandPaletteNucleoSearchIndex = nil
        cachedCommandPaletteResults = []
        commandPaletteVisibleResults = []
        commandPaletteVisibleResultsScope = nil
        commandPaletteVisibleResultsFingerprint = nil
        commandPaletteVisibleResultsVersion &+= 1
        cachedCommandPaletteScope = nil
        cachedCommandPaletteFingerprint = nil
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteResolvedSearchRequestID = commandPaletteSearchRequestID
        commandPaletteResolvedSearchScope = nil
        commandPaletteResolvedSearchFingerprint = nil
        commandPaletteTerminalOpenTargetAvailability = []
        isCommandPaletteSearchPending = false
        commandPalettePendingActivation = nil
        commandPaletteResultsRevision &+= 1
        syncCommandPaletteOverlayCommandListState()
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        requestCommandPaletteFocusRestore(target: focusTarget)
    }

    private func handleCommandPaletteBackdropClick(atContentPoint contentPoint: CGPoint) {
        let clickedFocusTarget = commandPaletteBackdropFocusTarget(atContentPoint: contentPoint)
#if DEBUG
        if let clickedFocusTarget {
            cmuxDebugLog(
                "palette.dismiss.backdrop focusTarget panel=\(clickedFocusTarget.panelId.uuidString.prefix(5)) " +
                "workspace=\(clickedFocusTarget.workspaceId.uuidString.prefix(5)) intent=\(debugCommandPaletteFocusIntent(clickedFocusTarget.intent))"
            )
        } else {
            cmuxDebugLog("palette.dismiss.backdrop focusTarget=nil")
        }
#endif
        dismissCommandPalette(restoreFocus: true, preferredFocusTarget: clickedFocusTarget)
    }

    private func commandPaletteBackdropFocusTarget(atContentPoint contentPoint: CGPoint) -> CommandPaletteRestoreFocusTarget? {
        guard let window = observedWindow,
              let contentView = window.contentView else {
            return nil
        }

        let nsContentPoint = NSPoint(x: contentPoint.x, y: contentPoint.y)
        let windowPoint = contentView.convert(nsContentPoint, to: nil)
        return commandPaletteBackdropFocusTarget(atWindowPoint: windowPoint, in: window)
    }

    private func commandPaletteBackdropFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        let overlayController = commandPaletteWindowOverlayController(for: window)
        if let responder = overlayController.underlyingResponder(atWindowPoint: windowPoint),
           let target = commandPaletteBackdropFocusTarget(for: responder) {
            return target
        }

        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: window
            )
        }

        return nil
    }

    private func commandPaletteBackdropFocusTarget(for responder: NSResponder) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = cmuxOwningGhosttyView(for: responder),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: observedWindow
            )
        }

        if let webView = commandPaletteOwningWebView(for: responder),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(for webView: WKWebView) -> CommandPaletteRestoreFocusTarget? {
        if let selectedWorkspace = tabManager.selectedWorkspace,
           let target = commandPaletteBrowserFocusTarget(in: selectedWorkspace, for: webView) {
            return target
        }

        let selectedWorkspaceId = tabManager.selectedTabId
        for workspace in tabManager.tabs where workspace.id != selectedWorkspaceId {
            if let target = commandPaletteBrowserFocusTarget(in: workspace, for: webView) {
                return target
            }
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(
        in workspace: Workspace,
        for webView: WKWebView
    ) -> CommandPaletteRestoreFocusTarget? {
        for (panelId, panel) in workspace.panels {
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.webView === webView else {
                continue
            }

            return commandPaletteRestoreFocusTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                fallbackIntent: .browser(.webView),
                in: observedWindow
            )
        }

        return nil
    }

    private func commandPaletteRestoreFocusTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent,
        in window: NSWindow?
    ) -> CommandPaletteRestoreFocusTarget {
        let intent = tabManager.tabs
            .first(where: { $0.id == workspaceId })?
            .panels[panelId]?
            .captureFocusIntent(in: window) ?? fallbackIntent

        return CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        commandPalettePendingDismissFocusTarget = target
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        let timeoutWork = DispatchWorkItem {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem = nil
        }
        commandPaletteRestoreTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutWork)
        attemptCommandPaletteFocusRestoreIfNeeded()
    }

    private func attemptCommandPaletteFocusRestoreIfNeeded() {
        guard !isCommandPalettePresented else { return }
        guard let target = commandPalettePendingDismissFocusTarget else { return }
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem?.cancel()
            commandPaletteRestoreTimeoutWorkItem = nil
            return
        }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(
            target.workspaceId,
            surfaceId: target.panelId,
            suppressFlash: true,
            dismissRestoredUnreadOnResume: true
        )

        guard let context = focusedPanelContext,
              context.workspace.id == target.workspaceId,
              context.panelId == target.panelId else {
            return
        }
        guard context.panel.restoreFocusIntent(target.intent) else { return }
        commandPalettePendingDismissFocusTarget = nil
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        commandPaletteRestoreTimeoutWorkItem = nil
    }

#if DEBUG
    private func debugCommandPaletteFocusIntent(_ intent: PanelFocusIntent) -> String {
        switch intent {
        case .panel:
            return "panel"
        case .terminal(.surface):
            return "terminal.surface"
        case .terminal(.findField):
            return "terminal.findField"
        case .terminal(.textBoxInput):
            return "terminal.textBoxInput"
        case .browser(.webView):
            return "browser.webView"
        case .browser(.addressBar):
            return "browser.addressBar"
        case .browser(.findField):
            return "browser.findField"
        case .filePreview(.textEditor):
            return "filePreview.textEditor"
        case .filePreview(.pdfCanvas):
            return "filePreview.pdfCanvas"
        case .filePreview(.pdfThumbnails):
            return "filePreview.pdfThumbnails"
        case .filePreview(.pdfOutline):
            return "filePreview.pdfOutline"
        case .filePreview(.imageCanvas):
            return "filePreview.imageCanvas"
        case .filePreview(.mediaPlayer):
            return "filePreview.mediaPlayer"
        case .filePreview(.quickLook):
            return "filePreview.quickLook"
        case .project(.navigator):
            return "project.navigator"
        case .project(.detail):
            return "project.detail"
        }
    }

    private func debugCommandPaletteModeLabel(_ mode: CommandPaletteMode) -> String {
        switch mode {
        case .commands:
            return "commands"
        case .renameInput:
            return "renameInput"
        case .renameConfirm:
            return "renameConfirm"
        case .workspaceDescriptionInput:
            return "workspaceDescriptionInput"
        }
    }
#endif

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func resetCommandPaletteWorkspaceDescriptionFocus() {
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.focus.reset schedule presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
        DispatchQueue.main.async {
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.focus.reset apply.before search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
            isCommandPaletteSearchFocused = false
            isCommandPaletteRenameFocused = false
            commandPaletteShouldFocusWorkspaceDescriptionEditor = true
            commandPalettePendingTextSelectionBehavior = nil
#if DEBUG
            cmuxDebugLog(
                "palette.wsDescription.focus.reset apply.after search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    private func handleCommandPaletteRenameInputInteraction() {
        guard isCommandPalettePresented else { return }
        guard case .renameInput = commandPaletteMode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        let selectAllOnFocus = CommandPaletteSettingsStore(defaults: .standard).renameSelectsAllOnFocus
        let selectionBehavior: CommandPaletteTextSelectionBehavior = selectAllOnFocus
            ? .selectAll
            : .caretAtEnd
        return CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: selectionBehavior
        )
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            commandPaletteShouldFocusWorkspaceDescriptionEditor = false
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(_ behavior: CommandPaletteTextSelectionBehavior) {
        commandPalettePendingTextSelectionBehavior = behavior
        attemptCommandPaletteTextSelectionIfNeeded()
    }

    private func attemptCommandPaletteTextSelectionIfNeeded() {
        guard isCommandPalettePresented else {
            commandPalettePendingTextSelectionBehavior = nil
            return
        }
        guard let behavior = commandPalettePendingTextSelectionBehavior else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteMode {
            case .commands, .renameInput:
                break
            case .renameConfirm:
                return
            case .workspaceDescriptionInput:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else {
            return
        }
        let length = (editor.string as NSString).length
        switch behavior {
        case .selectAll:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .caretAtEnd:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        commandPalettePendingTextSelectionBehavior = nil
    }

    private func refreshCommandPaletteUsageHistory() {
        commandPaletteUsageHistoryByCommandId = loadCommandPaletteUsageHistory()
    }

    private func loadCommandPaletteUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.commandPaletteUsageDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistCommandPaletteUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandPaletteUsageDefaultsKey)
    }

    private func recordCommandPaletteUsage(_ commandId: String) {
        var history = commandPaletteUsageHistoryByCommandId
        var entry = history[commandId] ?? CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        history[commandId] = entry
        commandPaletteUsageHistoryByCommandId = history
        persistCommandPaletteUsageHistory(history)
    }

    private func commandPaletteHistoryBoost(for commandId: String, queryIsEmpty: Bool) -> Int {
        CommandPaletteSearchOrchestrator.historyBoost(
            for: commandId,
            queryIsEmpty: queryIsEmpty,
            history: commandPaletteUsageHistoryByCommandId,
            now: Date().timeIntervalSince1970
        )
    }

    private func selectedWorkspaceIndex() -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return tabManager.tabs.firstIndex { $0.id == workspace.id }
    }

    private func moveSelectedWorkspace(by delta: Int) {
        guard let workspace = tabManager.selectedWorkspace,
              let currentIndex = selectedWorkspaceIndex() else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex)
        tabManager.selectWorkspace(workspace)
    }

    private func closeWorkspaceIds(_ workspaceIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    private func closeOtherSelectedWorkspaces() {
        guard let workspace = tabManager.selectedWorkspace else { return }
        let workspaceIds = tabManager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesBelow() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesAbove() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func syncSidebarSelectedWorkspaceIds() {
        tabManager.setSidebarSelectedWorkspaceIds(selectedTabIds)
    }

    private func applyUITestSidebarSelectionIfNeeded(tabs: [Workspace]) {
#if DEBUG
        guard !didApplyUITestSidebarSelection else { return }
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return
        }

        var indices: [Int] = []
        for token in rawValue.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = Int(trimmed), index >= 0 else { return }
            if !indices.contains(index) {
                indices.append(index)
            }
        }

        guard let lastIndex = indices.last, !indices.isEmpty, lastIndex < tabs.count else { return }

        let selectedIds = Set(indices.map { tabs[$0].id })
        selectedTabIds = selectedIds
        lastSidebarSelectionIndex = lastIndex
        tabManager.selectWorkspace(tabs[lastIndex])
        sidebarSelectionState.selection = .tabs
#if DEBUG
        UITestRecorder.record([
            "sidebarSelectedWorkspaceCount": String(selectedIds.count),
            "sidebarSelectedWorkspaceLastIndex": String(lastIndex),
            "sidebarWorkspaceCount": String(tabs.count),
        ])
#endif
        didApplyUITestSidebarSelection = true
#endif
    }

    private func beginRenameWorkspaceFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        startRenameFlow(target)
    }

    private func beginWorkspaceDescriptionFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspace.id,
            currentDescription: workspace.customDescription ?? ""
        )
        startWorkspaceDescriptionFlow(target)
    }

    private func beginRenameTabFlow() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
        startRenameFlow(target)
    }

    private func startRenameFlow(_ target: CommandPaletteRenameTarget) {
        commandPaletteRenameDraft = target.currentName
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func startWorkspaceDescriptionFlow(_ target: CommandPaletteWorkspaceDescriptionTarget) {
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.flow.start workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "descLen=\((target.currentDescription as NSString).length) " +
            "presented=\(isCommandPalettePresented ? 1 : 0) " +
            "modeBefore=\(debugCommandPaletteModeLabel(commandPaletteMode))"
        )
#endif
        commandPaletteWorkspaceDescriptionDraft = target.currentDescription
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteMode = .workspaceDescriptionInput(target)
        resetCommandPaletteWorkspaceDescriptionFocus()
#if DEBUG
        cmuxDebugLog(
            "palette.wsDescription.flow.armed workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "height=\(String(format: "%.1f", commandPaletteWorkspaceDescriptionHeight)) " +
            "modeAfter=\(debugCommandPaletteModeLabel(commandPaletteMode))"
        )
#endif
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func continueRenameFlow(target: CommandPaletteRenameTarget) {
        guard case .renameInput(let activeTarget) = commandPaletteMode,
              activeTarget == target else { return }
        applyRenameFlow(target: target, proposedName: commandPaletteRenameDraft)
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            tabManager.setCustomTitle(tabId: workspaceId, title: normalizedName)
        case .tab(let workspaceId, let panelId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalizedName)
        }

        dismissCommandPalette()
    }

    private func applyWorkspaceDescriptionFlow(
        target: CommandPaletteWorkspaceDescriptionTarget,
        proposedDescription: String
    ) {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            NSSound.beep()
            return
        }
#if DEBUG
        let newlineCount = proposedDescription.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        cmuxDebugLog(
            "palette.wsDescription.apply.begin workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "proposedLen=\((proposedDescription as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\(debugCommandPaletteTextPreview(proposedDescription))\""
        )
#endif
        tabManager.setCustomDescription(tabId: target.workspaceId, description: proposedDescription)
#if DEBUG
        if let updatedWorkspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }) {
            let persisted = updatedWorkspace.customDescription ?? ""
            let persistedNewlineCount = persisted.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "palette.wsDescription.apply.end workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "persistedLen=\((persisted as NSString).length) " +
                "persistedNewlines=\(persistedNewlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(persisted))\""
            )
        }
#endif
        dismissCommandPalette()
    }

    private func focusFocusedBrowserAddressBar() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel else { return false }
        _ = panel.requestAddressBarFocus(selectionIntent: .selectAll)
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        return true
    }

    private func openFocusedBrowserInDefaultBrowser() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel,
              let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openWorkspacePullRequestsInConfiguredBrowser() -> Bool {
        guard let workspace = tabManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }

        var openedCount = 0
        if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser() {
            for pullRequest in pullRequests {
                if tabManager.openBrowser(url: pullRequest.url, insertAtEnd: true) != nil {
                    openedCount += 1
                } else if NSWorkspace.shared.open(pullRequest.url) {
                    openedCount += 1
                }
            }
            return openedCount > 0
        }

        for pullRequest in pullRequests {
            if NSWorkspace.shared.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    private func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        case .vscodeInline:
            return openFocusedDirectoryInInlineVSCode(directoryURL)
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func openFocusedDirectoryInInlineVSCode(_ directoryURL: URL) -> Bool {
        AppDelegate.shared?.openDirectoryInInlineVSCode(directoryURL, tabManager: tabManager) ?? false
    }

    private func stopInlineVSCodeServeWeb() {
        VSCodeServeWebController.shared.stop()
    }

    private func restartInlineVSCodeServeWeb() -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }
        VSCodeServeWebController.shared.restart(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            if serveWebURL == nil {
                NSSound.beep()
            }
        }
        return true
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String = {
            if let focusedPanelId = workspace.focusedPanelId,
               let directory = workspace.panelDirectories[focusedPanelId] {
                return directory
            }
            return workspace.currentDirectory
        }()
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

#if DEBUG
    private func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif
}

private struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

private enum SidebarFontSizeProvider {
    static func loadFromGhosttyConfig() async -> CGFloat {
        await Task.detached(priority: .utility) {
            GhosttyConfig.load().sidebarFontSize
        }.value
    }
}

struct SidebarTabItemSettingsSnapshot: Equatable {
    let hidesAllDetails: Bool
    let wrapsWorkspaceTitles: Bool
    let showsWorkspaceDescription: Bool
    let sidebarShortcutHintXOffset: Double
    let sidebarShortcutHintYOffset: Double
    let alwaysShowShortcutHints: Bool
    let sidebarFontScale: CGFloat
    let showsGitBranch: Bool
    let usesVerticalBranchLayout: Bool
    let stacksBranchAndDirectory: Bool
    let usesLastSegmentPath: Bool
    let showsGitBranchIcon: Bool
    let showsSSH: Bool
    let makesPullRequestsClickable: Bool
    let openPullRequestLinksInCmuxBrowser: Bool
    let openPortLinksInCmuxBrowser: Bool
    let showsNotificationMessage: Bool
    let activeTabIndicatorStyle: WorkspaceIndicatorStyle
    let selectionColorHex: String?
    let notificationBadgeColorHex: String?
    let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
    let iMessageModeEnabled: Bool

    init(
        defaults: UserDefaults = .standard,
        sidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize
    ) {
        sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
        sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
        sidebarFontScale = SidebarTabItemFontScale.scale(for: sidebarFontSize)
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        usesVerticalBranchLayout = settings.value(for: catalog.sidebar.branchVerticalLayout)
        stacksBranchAndDirectory = settings.value(for: catalog.sidebar.stackBranchDirectory)
        usesLastSegmentPath = settings.value(for: catalog.sidebar.pathLastSegmentOnly)
        showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        showsSSH = Self.bool(defaults: defaults, key: "sidebarShowSSH", defaultValue: SidebarWorkspaceDetailDefaults.showSSH)
        makesPullRequestsClickable = settings.value(for: catalog.sidebar.makePullRequestsClickable)
        openPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(
            defaults: defaults
        )
        openPortLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(
            defaults: defaults
        )

        hidesAllDetails = settings.value(for: catalog.sidebar.hideAllDetails)
        wrapsWorkspaceTitles = SidebarWorkspaceTitleWrapSettings.wraps(defaults: defaults)
        let detailVisibility = SidebarWorkspaceDetailVisibility(
            showWorkspaceDescription: settings.value(for: catalog.sidebar.showWorkspaceDescription),
            showNotificationMessage: settings.value(for: catalog.sidebar.showNotificationMessage),
            hideAllDetails: hidesAllDetails
        )
        showsWorkspaceDescription = detailVisibility.showsWorkspaceDescription
        showsNotificationMessage = detailVisibility.showsNotificationMessage

        let showsMetadata = Self.bool(defaults: defaults, key: "sidebarShowStatusPills", defaultValue: SidebarWorkspaceDetailDefaults.showCustomMetadata)
        let showsLog = Self.bool(defaults: defaults, key: "sidebarShowLog", defaultValue: SidebarWorkspaceDetailDefaults.showLog)
        let showsProgress = Self.bool(defaults: defaults, key: "sidebarShowProgress", defaultValue: SidebarWorkspaceDetailDefaults.showProgress)
        let showsBranchDirectory = Self.bool(defaults: defaults, key: "sidebarShowBranchDirectory", defaultValue: SidebarWorkspaceDetailDefaults.showBranchDirectory)
        let showsPullRequests = Self.bool(defaults: defaults, key: "sidebarShowPullRequest", defaultValue: SidebarWorkspaceDetailDefaults.showPullRequests)
        let showsPorts = Self.bool(defaults: defaults, key: "sidebarShowPorts", defaultValue: SidebarWorkspaceDetailDefaults.showPorts)
        visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: showsMetadata,
            showLog: showsLog,
            showProgress: showsProgress,
            showBranchDirectory: showsBranchDirectory,
            showPullRequests: showsPullRequests,
            showPorts: showsPorts,
            hideAllDetails: hidesAllDetails
        )

        activeTabIndicatorStyle = settings.value(for: catalog.workspaceColors.indicatorStyle)
        selectionColorHex = defaults.string(forKey: "sidebarSelectionColorHex")
        notificationBadgeColorHex = defaults.string(forKey: "sidebarNotificationBadgeColorHex")
        iMessageModeEnabled = IMessageModeSettings.isEnabled(defaults: defaults)
    }

    private static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

}


enum CmuxExtensionSidebarSelection {
    static let defaultsKey = "cmuxExtensionSidebar.providerId"
    static let selectedExtensionNameDefaultsKey = "cmuxExtensionSidebar.selectedExtensionName"
    static let defaultProviderId = CmuxSidebarProviderDescriptor.defaultWorkspacesID
    static let hostedExtensionsProviderId = "cmux.sidebar.extensions"

    /// Synchronous read of the experimental Extensions flag for the on-demand
    /// AppKit/static paths (the toggle menu, the command-palette builder, the
    /// extensions-browser opener) that have no `SettingsRuntime` in scope and
    /// run outside the SwiftUI update cycle.
    ///
    /// SwiftUI views bind reactively via `@LiveSetting(\.betaFeatures.extensions)`.
    /// This synchronous read resolves the same catalog key
    /// (`BetaFeaturesCatalogSection.extensions`) against `UserDefaults`, which is
    /// the same suite and key the store persists to, so the catalog stays the
    /// single definition of the key, decode, and default.
    static var isEnabled: Bool {
        // Read the single beta-features section, not the whole `SettingCatalog`.
        // Constructing the full catalog allocates ~20 sub-sections (including
        // `AutomationCatalogSection`/`SecretFileKey`) just to reach one flag;
        // doing that on the SwiftUI body's hot path turned the sidebar
        // re-render into a CPU catastrophe (issue #5970).
        let key = BetaFeaturesCatalogSection().extensions
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    static var providers: [any CmuxSidebarProvider] {
        SidebarExamples.providers
    }

    // MARK: - Custom sidebars (beta)

    /// Provider-id prefix for user/agent-authored custom sidebars. The
    /// suffix after the prefix is the sidebar's file base name.
    static let customSidebarProviderPrefix = "cmux.sidebar.custom."

    /// Synchronous read of the experimental custom-sidebars flag, mirroring
    /// ``isEnabled`` for the AppKit/static paths (the picker menu).
    static var customSidebarsEnabled: Bool {
        // See ``isEnabled``: read only the beta-features section so a body-path
        // access does not allocate the entire `SettingCatalog` (issue #5970).
        let key = BetaFeaturesCatalogSection().customSidebars
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Directory custom sidebars are authored into.
    static var customSidebarsDirectory: URL {
        #if DEBUG
        if let override = customSidebarsDirectoryOverrideForTesting { return override }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebars", isDirectory: true)
    }

    /// One provider descriptor per `<name>.swift`/`<name>.json` file in the
    /// sidebars directory (`.swift` preferred when both exist), titled by the
    /// file's base name.
    static var customSidebarDescriptors: [CmuxSidebarProviderDescriptor] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: customSidebarsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var extensionByName: [String: String] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "swift" || ext == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if extensionByName[name] == "swift" { continue }
            extensionByName[name] = ext
        }
        return extensionByName.keys.sorted().map { name in
            CmuxSidebarProviderDescriptor(
                id: customSidebarProviderPrefix + name,
                title: CmuxSidebarProviderLocalizedText(key: "sidebar.provider.custom.\(name)", defaultValue: name),
                subtitle: CmuxSidebarProviderLocalizedText(
                    key: "sidebar.provider.custom.subtitle",
                    defaultValue: String(localized: "sidebar.provider.custom.subtitle", defaultValue: "Custom sidebar")
                ),
                systemImageName: "wand.and.stars",
                isHostProvided: false
            )
        }
    }

    /// Resolves a custom-sidebar provider id to its backing file URL
    /// (`.swift` preferred), or `nil` if neither file exists.
    static func customSidebarFileURL(forProviderId providerId: String) -> URL? {
        customSidebarFileURL(forProviderId: providerId, sidebarsDirectory: customSidebarsDirectory)
    }

    static func customSidebarFileURL(forProviderId providerId: String, sidebarsDirectory: URL) -> URL? {
        guard providerId.hasPrefix(customSidebarProviderPrefix) else { return nil }
        let name = String(providerId.dropFirst(customSidebarProviderPrefix.count))
        guard isValidCustomSidebarFileBaseName(name) else { return nil }
        let swiftURL = sidebarsDirectory.appendingPathComponent("\(name).swift", isDirectory: false)
        if FileManager.default.fileExists(atPath: swiftURL.path) { return swiftURL }
        let jsonURL = sidebarsDirectory.appendingPathComponent("\(name).json", isDirectory: false)
        if FileManager.default.fileExists(atPath: jsonURL.path) { return jsonURL }
        return nil
    }

    private static func isValidCustomSidebarFileBaseName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name == (name as NSString).lastPathComponent
    }

    /// The always-available built-in views: the default workspaces sidebar plus
    /// the bundled preset providers (Project Worktrees, Attention Queue, Dev
    /// Servers, Last Prompt, Super Compact, Browser Stack). These ship
    /// independently of the experimental Extensions feature, so they stay in
    /// the switcher menu regardless of the beta flag.
    static var builtInDescriptors: [CmuxSidebarProviderDescriptor] {
        [.defaultWorkspaces] + providers.map { $0.descriptor }
    }

    /// Descriptors offered in the switcher menu and command palette. The hosted
    /// extension entry belongs to the experimental Extensions feature, so it is
    /// only offered while that beta is enabled; the built-in views are always
    /// offered.
    static var descriptors: [CmuxSidebarProviderDescriptor] {
        var result = isEnabled ? builtInDescriptors + [hostedExtensionsDescriptor] : builtInDescriptors
        if customSidebarsEnabled { result += customSidebarDescriptors }
        return result
    }

    /// Every descriptor that can ever be selected, ignoring feature gates. Used
    /// to register command-palette handlers so a runtime flag flip always has a
    /// handler to invoke; what is *shown* uses ``descriptors``.
    static var allDescriptors: [CmuxSidebarProviderDescriptor] {
        builtInDescriptors + [hostedExtensionsDescriptor] + customSidebarDescriptors
    }

    static var hostedExtensionsDescriptor: CmuxSidebarProviderDescriptor {
        let selectedName = UserDefaults.standard.string(forKey: selectedExtensionNameDefaultsKey)?.nilIfEmpty
        return CmuxSidebarProviderDescriptor(
            id: hostedExtensionsProviderId,
            title: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.extensions.title",
                defaultValue: selectedName ?? String(localized: "sidebar.provider.extensions.title", defaultValue: "Extension Sidebar")
            ),
            subtitle: CmuxSidebarProviderLocalizedText(
                key: "sidebar.provider.extensions.subtitle",
                defaultValue: selectedName == nil
                    ? String(localized: "sidebar.provider.extensions.subtitle", defaultValue: "Custom sidebar")
                    : String(localized: "sidebar.provider.extensions.selectedSubtitle", defaultValue: "Sidebar extension")
            ),
            systemImageName: "puzzlepiece.extension",
            isHostProvided: true
        )
    }

    static func descriptor(for providerId: String) -> CmuxSidebarProviderDescriptor {
        descriptors.first { $0.id == providerId } ?? .defaultWorkspaces
    }

    /// Whether an already-`effectiveProviderId`-resolved selection renders the
    /// built-in default workspaces sidebar. This mirrors
    /// `descriptor(for:).id == defaultWorkspacesID` exactly for an effective id,
    /// but WITHOUT building the full ``descriptors`` list — which constructs a
    /// `SettingCatalog` twice (via ``isEnabled``/``customSidebarsEnabled``) and
    /// enumerates the custom-sidebars directory. Those are far too expensive to
    /// run on every SwiftUI body pass; doing so was the multiplier behind the
    /// ~100% CPU re-render loop in issue #5970. Only cheap static lookups and at
    /// most two `fileExists` probes run here, so it is safe for the body.
    ///
    /// The input must be ``effectiveProviderId``'s output: that already routes a
    /// hosted/custom selection back to the default sidebar while its feature gate
    /// is off, so this only needs to confirm the resolved id maps to a renderable
    /// non-default view.
    static func resolvesToDefaultSidebar(effectiveProviderId id: String) -> Bool {
        if id == defaultProviderId { return true }
        if id == hostedExtensionsProviderId { return false }
        if id.hasPrefix(customSidebarProviderPrefix) {
            // A custom selection survives only while its backing file exists;
            // otherwise the descriptor lookup falls back to the default sidebar.
            return customSidebarFileURL(forProviderId: id) == nil
        }
        // Bundled preset providers are always registered regardless of any beta
        // flag; an unknown/stale id has no provider and falls back to default.
        return provider(for: id) == nil
    }

    static func provider(for providerId: String) -> (any CmuxSidebarProvider)? {
        providers.first { $0.descriptor.id == providerId }
    }

    /// Resolves the persisted provider selection to the provider that is
    /// actually rendered. The hosted-extensions provider is part of the
    /// experimental Extensions feature, so a persisted hosted selection falls
    /// back to the default workspaces sidebar while the beta is disabled,
    /// otherwise turning the feature off would strand the user on an empty
    /// sidebar with no switcher entry to escape it. Built-in views are always
    /// honored, so the switcher and its active-view checkmark keep working
    /// regardless of the beta flag.
    static func effectiveProviderId(_ persistedProviderId: String, extensionsEnabled: Bool) -> String {
        if persistedProviderId == hostedExtensionsProviderId, !extensionsEnabled {
            return defaultProviderId
        }
        return persistedProviderId
    }

    static func localizedTitle(for descriptor: CmuxSidebarProviderDescriptor) -> String {
        localizedText(descriptor.title)
    }

    static func localizedText(_ text: CmuxSidebarProviderLocalizedText) -> String {
        NSLocalizedString(
            text.key,
            tableName: "Localizable",
            bundle: .main,
            value: text.defaultValue,
            comment: ""
        )
    }

    static func setProviderId(_ providerId: String, defaults: UserDefaults = .standard) {
        defaults.set(providerId, forKey: defaultsKey)
    }

    @MainActor
    static func showMenu(anchorView: NSView, event: NSEvent?) {
        // The right-click menu switches between the always-available built-in
        // views (and the hosted extension sidebar when the experimental
        // Extensions beta is enabled, plus any beta custom sidebars), so it is
        // shown regardless of the flag.
        let menu = NSMenu()
        let persistedProviderId = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultProviderId
        let selectedProviderId = descriptor(
            for: effectiveProviderId(persistedProviderId, extensionsEnabled: isEnabled)
        ).id
        for descriptor in descriptors {
            let item = NSMenuItem(
                title: localizedTitle(for: descriptor),
                action: #selector(CmuxExtensionSidebarMenuTarget.selectProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = descriptor.id
            item.target = CmuxExtensionSidebarMenuTarget.shared
            item.state = selectedProviderId == descriptor.id ? .on : .off
            item.image = NSImage(systemSymbolName: descriptor.systemImageName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
    }
}

@MainActor
private final class CmuxExtensionSidebarMenuTarget: NSObject {
    static let shared = CmuxExtensionSidebarMenuTarget()

    @objc func selectProvider(_ sender: NSMenuItem) {
        guard let providerId = sender.representedObject as? String else { return }
        CmuxExtensionSidebarSelection.setProviderId(providerId)
    }
}

@MainActor
private final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private let sidebarFontSizeProvider: () async -> CGFloat
    private var sidebarFontSize: CGFloat
    private var sidebarFontSizeLoadTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var ghosttyConfigObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        initialSidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize,
        sidebarFontSizeProvider: @escaping () async -> CGFloat = SidebarFontSizeProvider.loadFromGhosttyConfig
    ) {
        self.defaults = defaults
        self.sidebarFontSize = GhosttyConfig.clampedSidebarFontSize(initialSidebarFontSize)
        self.sidebarFontSizeProvider = sidebarFontSizeProvider
        self.snapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
        refreshSidebarFontSize()
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSidebarFontSize()
            }
        }
    }

    deinit {
        sidebarFontSizeLoadTask?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let ghosttyConfigObserver {
            NotificationCenter.default.removeObserver(ghosttyConfigObserver)
        }
    }

    private func refreshSnapshot() {
        let nextSnapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            sidebarFontSize: sidebarFontSize
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func refreshSidebarFontSize() {
        sidebarFontSizeLoadTask?.cancel()
        sidebarFontSizeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loadedSidebarFontSize = await sidebarFontSizeProvider()
            guard !Task.isCancelled else { return }
            sidebarFontSize = GhosttyConfig.clampedSidebarFontSize(loadedSidebarFontSize)
            refreshSnapshot()
        }
    }
}

// `SidebarDragState`, `SidebarWorkspaceDragRegistry`, and the DEBUG-only
// `SidebarDragStateRegistry` now live in the `CmuxSidebar`// package. This app-side convenience keeps the `SidebarDragState()` call site
// unchanged by injecting the process-wide cross-window registry the app owns
// at its composition root (`AppDelegate`).
extension SidebarDragState {
    /// Builds a drag state wired to the app's process-wide cross-window drag
    /// registry. Falls back to a fresh registry only if `AppDelegate.shared` is
    /// not yet available (never the case once a sidebar has mounted).
    convenience init() {
        self.init(
            workspaceDragRegistry: AppDelegate.shared?.sidebarWorkspaceDragRegistry
                ?? SidebarWorkspaceDragRegistry()
        )
    }
}

/// Freezes `showsModifierShortcutHints` for the row whose context menu is open,
/// so pressing/releasing the modifier key while the menu is up does not flip
/// the underlying row's shortcut badges (which would be visible around the
/// open context menu). All other rows transition live.
struct VerticalTabsSidebar: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let windowId: UUID
    let onSendFeedback: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let observedWindow: NSWindow?
    @EnvironmentObject var tabManager: TabManager
    // Observe the coalesced unread projection instead of the notification store
    // so notification churn (terminal/agent activity) no longer reconstructs
    // every workspace row. The store stays available as an unobserved singleton
    // for context-menu actions and pass-down. See SidebarUnreadModel / #2586.
    @EnvironmentObject var sidebarUnread: SidebarUnreadModel
    var notificationStore: TerminalNotificationStore { .shared }
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var sidebarRenderWorkerClient: RenderWorkerClient?
    @State var modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @StateObject var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @StateObject private var tabItemSettingsStore = SidebarTabItemSettingsStore(
        initialSidebarFontSize: GhosttyConfig.load().sidebarFontSize
    )
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State var dragState = SidebarDragState()
    // Bonsplit tab drags arrive through AppKit pasteboard callbacks, not
    // `SidebarDragState`, so they need a separate transient collection flag.
    @State private var isBonsplitWorkspaceDropTargetCollectionActive = false
    @State private var bonsplitWorkspaceDropTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
    @State private var isWorkspaceReorderDropTargetCollectionActive = false
    @State private var workspaceReorderDropTargetBridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
    // Freezes `showsModifierShortcutHints` for the workspace whose context menu
    // is open. Set on the row's contextMenu.onAppear and cleared on
    // .onDisappear so modifier-key transitions don't flip the badges on the
    // row sitting behind the open menu. See `SidebarShortcutHintFreezePolicy`.
    @State private var frozenShortcutHintsTabId: UUID?
    @State private var frozenShortcutHintsValue: Bool = false
    @State private var pendingSelectedWorkspaceScrollId: UUID?
    @State private var collapsedExtensionSidebarSectionIds: Set<String> = []
    @State private var extensionSidebarWorktreeCreationInFlightSectionIds: Set<String> = []
    @State private var extensionSidebarUpdateToken: UInt64 = 0
    // Stable, memoized merged observation publishers for the extension
    // sidebar's `.onReceive` handlers. Rebuilding them inline each body pass
    // re-subscribed `.onReceive` to a fresh publisher every render, replaying
    // the current value and re-bumping `extensionSidebarUpdateToken` in a
    // ~100% CPU loop (issue #5970).
    @State private var extensionSidebarObservationWorkspaceIds: [UUID] = []
    @State private var extensionSidebarObservationPublishersBuilt = false
    @State private var extensionSidebarImmediateObservationPublisher: AnyPublisher<Void, Never> =
        Empty<Void, Never>().eraseToAnyPublisher()
    @State private var extensionSidebarDebouncedObservationPublisher: AnyPublisher<Void, Never> =
        Empty<Void, Never>().eraseToAnyPublisher()
    /// Bumped whenever any workspace's currentDirectory changes; the group
    /// header's resolved cwd-based config (color/icon/context menu /
    /// newWorkspacePlacement) reads it through the body, so a state
    /// invalidation here forces SwiftUI to re-call
    /// `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`. The anchor
    /// has no TabItemView, so no implicit per-row publisher subscription
    /// would otherwise fire on `cd` while it's not selected.
    @State private var anchorCwdRevision: Int = 0
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    private var selectedExtensionSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) private var customSidebarsExperimentalEnabled
    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints

    // The provider to actually render. Built-in views are always honored; only
    // the hosted-extension selection falls back to the default workspaces
    // sidebar while the experimental Extensions feature is disabled, since
    // turning extensions off hides that entry and would otherwise strand the
    // user with no way back. Deriving the effective provider (rather than
    // mutating the persisted selection via an observer) routes correctly on the
    // first render pass and restores the user's choice if extensions are
    // re-enabled. Reading `extensionsExperimentalEnabled` here keeps the view
    // reactive to the flag toggling.
    private var effectiveExtensionSidebarProviderId: String {
        let selected = selectedExtensionSidebarProviderId
        if selected.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix) {
            // Touch the @LiveSetting so toggling the flag in Settings still
            // re-renders, but decide with the synchronous UserDefaults read:
            // on a sidebar remount @LiveSetting's initial value lags one tick,
            // which would otherwise flash the default sidebar for a frame
            // before swapping to the custom one.
            _ = customSidebarsExperimentalEnabled
            return CmuxExtensionSidebarSelection.customSidebarsEnabled
                ? selected
                : CmuxExtensionSidebarSelection.defaultProviderId
        }
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selectedExtensionSidebarProviderId,
            extensionsEnabled: extensionsExperimentalEnabled
        )
    }

    /// Live, read-only projection of workspace state handed to custom
    /// sidebars so interpreted Swift can bind to it (e.g.
    /// `ForEach(workspaces) { w in Text(w.title) }`) and re-render when it
    /// changes. A value snapshot built fresh each render, never the store
    /// itself, so it respects the sidebar snapshot-boundary rule.
    private func customSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            customSidebarWorkspaceSnapshot(workspace, index: index, selectedId: selectedId)
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: sidebarUnread.totalUnreadCount,
            now: now
        )
        return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
    }

    /// Projects one workspace's live state into the interpreter input snapshot.
    /// The SwiftValue assembly and optional-field omission rules live in
    /// `CustomSidebarDataContextBuilder`; keep the projected fields in sync with
    /// the data keys documented in `docs/custom-sidebars.md`.
    private func customSidebarWorkspaceSnapshot(_ workspace: Workspace, index: Int, selectedId: UUID?) -> CustomSidebarWorkspaceSnapshot {
        let focusedPanelId = workspace.focusedPanelId
        let firstBranch = workspace.sidebarGitBranchesInDisplayOrder().first
        let progress = workspace.progress.map {
            CustomSidebarWorkspaceSnapshot.Progress(value: $0.value, label: $0.label)
        }
        let remote = workspace.remoteDisplayTarget.map { target in
            CustomSidebarWorkspaceSnapshot.Remote(
                target: target,
                stateRawValue: workspace.remoteConnectionState.rawValue,
                isConnected: workspace.remoteConnectionState == .connected
            )
        }
        return CustomSidebarWorkspaceSnapshot(
            id: workspace.id,
            title: workspace.customTitle ?? workspace.title,
            isSelected: workspace.id == selectedId,
            isPinned: workspace.isPinned,
            index: index,
            directory: workspace.currentDirectory,
            listeningPorts: workspace.listeningPorts,
            unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id),
            surfaces: customSidebarSurfaceSnapshots(workspace, focusedPanelId: focusedPanelId),
            surfaceCount: workspace.bonsplitController.allPaneIds.reduce(0) { $0 + workspace.bonsplitController.tabs(inPane: $1).count },
            customDescription: workspace.customDescription,
            customColor: workspace.customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: workspace.customSidebarPullRequestValues(),
            progress: progress,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            remote: remote
        )
    }

    /// Projects a workspace's surfaces (terminal/browser/etc. tabs) into the
    /// interpreter input snapshots, enriched with per-surface directory, pin,
    /// git, and ports where available.
    private func customSidebarSurfaceSnapshots(_ workspace: Workspace, focusedPanelId: UUID?) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                let git = workspace.panelGitBranches[panelId]
                surfaces.append(
                    CustomSidebarSurfaceSnapshot(
                        panelId: panelId,
                        title: tab.title,
                        isFocused: panelId == focusedPanelId,
                        isPinned: workspace.pinnedPanelIds.contains(panelId),
                        directory: workspace.panelDirectories[panelId],
                        gitBranch: git?.branch,
                        gitIsDirty: git?.isDirty ?? false,
                        listeningPorts: workspace.surfaceListeningPorts[panelId] ?? []
                    )
                )
            }
        }
        return surfaces
    }
    @AppStorage("sidebarMatchTerminalBackground")
    private var sidebarMatchTerminalBackground = false
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset

    let tabRowSpacing: CGFloat = 2
    private static let extensionSidebarObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    private static let extensionSidebarDisclosureAnimation = Animation.easeInOut(duration: 0.18)
    private var sidebarTitlebarInteractionHeight: CGFloat {
        MinimalModeChromeMetrics.titlebarHeight
    }

    /// Adapter binding for unmigrated consumers (extension sidebar drop
    /// delegates, bonsplit overlays) that still expect @Binding<UUID?>. Reads
    /// flow through `dragState.draggedTabId` so @Observable per-property
    /// tracking still applies to whoever calls the binding's get.
    private var draggedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { dragState.draggedTabId },
            // Route the clear through `clearDrag()` so a locally originated drag
            // also ends its `SidebarWorkspaceDragRegistry` entry. The extension /
            // browser-stack sidebar drop delegates end drags by writing `nil`
            // through this binding; without this they'd leave the process-wide
            // registry stale and a later cross-window drop could act on it.
            set: { newValue in
                if let newValue {
                    dragState.draggedTabId = newValue
                } else {
                    dragState.clearDrag()
                }
            }
        )
    }

    /// Adapter binding mirroring `draggedTabIdBinding`. See its doc comment.
    private var dropIndicatorBinding: Binding<SidebarDropIndicator?> {
        Binding(
            get: { dragState.dropIndicator },
            set: { dragState.setDropIndicator($0) }
        )
    }

    /// Computed in the parent so `SidebarEmptyArea` can render its top-edge
    /// indicator from a value snapshot without holding a `SidebarDragState`
    /// reference (snapshot-boundary rule). Delegates to a pure predicate so
    /// the logic is unit-testable in isolation from view state.
    private func emptyAreaTopDropIndicatorVisible() -> Bool {
        let reorderIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            usesTopLevelRows: dragState.dropIndicatorUsesTopLevelRows
        )
        return SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            lastTabId: reorderIds.last,
            indicatorScope: dragState.dropIndicatorScope
        )
    }

    /// Constructs the drop delegate for the empty area in the parent scope,
    /// so the child view receives a closure-bundle-equivalent value rather
    /// than an `@Observable` store.
    private func emptyAreaTabDropDelegate(renderContext: WorkspaceListRenderContext) -> SidebarTabDropDelegate {
        SidebarTabDropDelegate(
            targetTabId: nil,
            tabManager: tabManager,
            workspaceGroupIdByWorkspaceId: renderContext.workspaceGroupIdByWorkspaceId,
            dragState: dragState,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: nil,
            dragAutoScrollController: dragAutoScrollController
        )
    }

    private func sidebarDropIndicatorRowIds(
        draggedWorkspaceId: UUID,
        scope: SidebarWorkspaceReorderDropIndicatorScope,
        tabs: [Workspace],
        workspaceGroups: [WorkspaceGroup],
        visibleWorkspaceRowIds: [UUID]
    ) -> [UUID] {
        switch scope {
        case .raw:
            return tabs.map(\.id)
        case .topLevel:
            return tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedWorkspaceId,
                usesTopLevelRows: true
            )
        case .group(let groupId):
            guard workspaceGroups.contains(where: { $0.id == groupId }) else { return [] }
            let visibleIds = Set(visibleWorkspaceRowIds)
            return tabs.filter { $0.groupId == groupId && visibleIds.contains($0.id) }.map(\.id)
        }
    }

    private var sidebarTopScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.topScrimHeight
    }

    private var sidebarBottomScrimHeight: CGFloat {
        SidebarWorkspaceListMetrics.bottomScrimHeight
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        )
    }

    private var minimalModeSidebarTitlebarControlsTopPadding: CGFloat {
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    private var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
    }

    private func requestSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        renderContext: WorkspaceListRenderContext
    ) {
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              renderContext.workspaceIds.contains(selectedWorkspaceId) else {
            pendingSelectedWorkspaceScrollId = nil
            return
        }

        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
        flushPendingSelectedWorkspaceScroll(proxy, renderContext: renderContext)
    }

    private func flushPendingSelectedWorkspaceScroll(
        _ proxy: ScrollViewProxy,
        renderContext: WorkspaceListRenderContext
    ) {
        guard let selectedWorkspaceId = pendingSelectedWorkspaceScrollId else { return }

        // Scroll unconditionally: ScrollViewProxy resolves `.id(_:)` values in
        // lazy containers without requiring the row to be realized, and an
        // unknown id is a harmless no-op. The previous design gated this on a
        // per-row "laid-out row ids" PreferenceKey whose sidebar-wide reduce
        // fed `@State` writes from inside the layout/preference update cycle,
        // the cmux-owned edge in the sidebar layout livelock
        // (https://github.com/manaflow-ai/cmux/issues/2586). No anchor means
        // SwiftUI scrolls the minimum needed to reveal the row.
        let group = renderContext.workspaceById[selectedWorkspaceId]?.groupId
            .flatMap { renderContext.workspaceGroupById[$0] }
        proxy.scrollTo(SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
            selectedWorkspaceId: selectedWorkspaceId,
            group: group
        ))
        pendingSelectedWorkspaceScrollId = nil
    }

    private func shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
        from oldWorkspaceIds: [UUID],
        to newWorkspaceIds: [UUID]
    ) -> Bool {
        SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
            selectedWorkspaceId: tabManager.selectedTabId,
            oldWorkspaceIds: oldWorkspaceIds,
            newWorkspaceIds: newWorkspaceIds
        )
    }

    private func requestSelectedWorkspaceScrollAfterWorkspaceOrderChange(_ notification: Notification) {
        guard let manager = notification.object as? TabManager, manager === tabManager else {
            return
        }
        guard let selectedWorkspaceId = tabManager.selectedTabId else { return }
        let movedWorkspaceIds = notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
        guard movedWorkspaceIds.contains(selectedWorkspaceId) else { return }
        pendingSelectedWorkspaceScrollId = selectedWorkspaceId
    }

    struct WorkspaceListRenderContext {
        let tabs: [Workspace]
        /// Stored snapshot of `tabs.map(\.id)` so per-row predicates that need
        /// it (e.g. `SidebarTabDropIndicatorPredicate.topVisible`) don't pay
        /// O(n) per row.
        let tabIds: [UUID]
        /// Drag-scope row ids shared by every visible row for this render pass.
        let sidebarReorderIds: [UUID]
        let workspaceCount: Int
        let canCloseWorkspace: Bool
        let workspaceNumberShortcut: StoredShortcut
        let tabItemSettings: SidebarTabItemSettingsSnapshot
        let pinResolutionContext: WorkspaceActionDispatcher.PinResolutionContext
        let tabIndexById: [UUID: Int]
        let workspaceById: [UUID: Workspace]
        let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
        let selectedContextTargetIds: [UUID]
        let selectedRemoteContextMenuWorkspaceIds: [UUID]
        let allSelectedRemoteContextMenuTargetsConnecting: Bool
        let allSelectedRemoteContextMenuTargetsDisconnected: Bool
        let workspaceGroups: [WorkspaceGroup]
        let workspaceGroupById: [UUID: WorkspaceGroup]
        let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
        let workspaceRenderItems: [SidebarWorkspaceRenderItem]
        let visibleWorkspaceRowIds: [UUID]

        var workspaceIds: [UUID] { tabIds }
    }

    var body: some View {
        let tabs = tabManager.tabs
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIds = tabs.map(\.id)
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let pinResolutionContext = WorkspaceActionDispatcher.PinResolutionContext(
            workspacesById: workspaceById,
            liveWorkspaceIds: Set(tabIds)
        )
        let workspaceGroupIdByWorkspaceId = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.groupId) })
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let selectedRemoteContextMenuTargets = orderedSelectedTabs.filter { $0.isRemoteWorkspace }
        let selectedRemoteContextMenuWorkspaceIds = selectedRemoteContextMenuTargets.map(\.id)
        let allSelectedRemoteContextMenuTargetsConnecting = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy {
                $0.remoteConnectionState == .connecting || $0.remoteConnectionState == .reconnecting
            }
        let allSelectedRemoteContextMenuTargetsDisconnected = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected }
        let workspaceGroups = tabManager.workspaceGroups
        let workspaceGroupById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let workspaceGroupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: workspaceGroups.map { WorkspaceGroupMenuSnapshot.Item(id: $0.id, name: $0.name) }
        )
        let workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: workspaceGroupById
        )
        let visibleWorkspaceRowIds = workspaceRenderItems.map(\.rowWorkspaceId)
        let draggedSidebarTabId = dragState.draggedTabId
        let dropIndicatorScope = dragState.dropIndicatorScope
        let sidebarReorderIds = draggedSidebarTabId.map {
            sidebarDropIndicatorRowIds(
                draggedWorkspaceId: $0,
                scope: dropIndicatorScope,
                tabs: tabs,
                workspaceGroups: workspaceGroups,
                visibleWorkspaceRowIds: visibleWorkspaceRowIds
            )
        } ?? []
        let renderContext = WorkspaceListRenderContext(
            tabs: tabs,
            tabIds: tabIds,
            sidebarReorderIds: sidebarReorderIds,
            workspaceCount: workspaceCount,
            canCloseWorkspace: canCloseWorkspace,
            workspaceNumberShortcut: workspaceNumberShortcut,
            tabItemSettings: tabItemSettings,
            pinResolutionContext: pinResolutionContext,
            tabIndexById: tabIndexById,
            workspaceById: workspaceById,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId,
            selectedContextTargetIds: selectedContextTargetIds,
            selectedRemoteContextMenuWorkspaceIds: selectedRemoteContextMenuWorkspaceIds,
            allSelectedRemoteContextMenuTargetsConnecting: allSelectedRemoteContextMenuTargetsConnecting,
            allSelectedRemoteContextMenuTargetsDisconnected: allSelectedRemoteContextMenuTargetsDisconnected,
            workspaceGroups: workspaceGroups,
            workspaceGroupById: workspaceGroupById,
            workspaceGroupMenuSnapshot: workspaceGroupMenuSnapshot,
            workspaceRenderItems: workspaceRenderItems,
            visibleWorkspaceRowIds: visibleWorkspaceRowIds
        )

        ZStack(alignment: .bottomLeading) {
            if CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(effectiveProviderId: effectiveExtensionSidebarProviderId) {
                workspaceScrollArea(renderContext: renderContext)
            } else {
                extensionSidebarScrollArea(renderContext: renderContext)
            }
            SidebarFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .overlay(alignment: .trailing) {
            WindowChromeBorder(
                orientation: .vertical,
                refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
            )
        }
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                modifierKeyMonitor.setHostWindow(showModifierHoldHints ? window : nil)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if showModifierHoldHints {
                modifierKeyMonitor.setHostWindow(observedWindow)
                modifierKeyMonitor.start()
            } else {
                modifierKeyMonitor.stop()
            }
            dragState.clearDrag()
            isBonsplitWorkspaceDropTargetCollectionActive = false
            isWorkspaceReorderDropTargetCollectionActive = false
            // Defensive reset: if a prior simulation died without running
            // its teardown (sidebar unmounted mid-loop, app crash, etc.) the
            // @State SidebarDragState could carry isSimulated=true into a
            // re-mount, which would silently bypass the real-drag failsafe.
            dragState.isSimulated = false
            #if DEBUG
            AppDelegate.shared?.sidebarDragStateRegistry.register(windowId: windowId, dragState: dragState)
            #endif
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            modifierKeyMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            dragState.clearDrag()
            isBonsplitWorkspaceDropTargetCollectionActive = false
            isWorkspaceReorderDropTargetCollectionActive = false
            // Clear the simulator flag too so a re-mounted sidebar doesn't
            // inherit a stale bypass and skip the real-drag failsafe monitor.
            dragState.isSimulated = false
            #if DEBUG
            AppDelegate.shared?.sidebarDragStateRegistry.unregister(windowId: windowId)
            #endif
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: showModifierHoldHints) { _, enabled in
            if enabled {
                modifierKeyMonitor.setHostWindow(observedWindow)
                modifierKeyMonitor.start()
            } else {
                modifierKeyMonitor.stop()
                frozenShortcutHintsTabId = nil
                frozenShortcutHintsValue = false
            }
        }
        .onChange(of: dragState.draggedTabId) { newDraggedTabId in
            SidebarDragLifecycleNotification().postStateDidChange(
                tabId: newDraggedTabId,
                reason: "drag_state_change"
            )
#if DEBUG
            cmuxDebugLog("sidebar.dragState.sidebar tab=\(debugShortSidebarTabId(newDraggedTabId))")
#endif
            if newDraggedTabId != nil {
                // The failsafe monitor probes the real mouse-button state and
                // posts `mouse_up_failsafe` if no mouse is held down. That's
                // correct for HID-driven drags, but `debug.sidebar.simulate_drag`
                // drives the state without any mouse, so skip the monitor when
                // a simulated drag is in flight.
                if !dragState.isSimulated {
                    dragFailsafeMonitor.start {
                        SidebarDragLifecycleNotification().postClearRequest(reason: $0)
                    }
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dragState.clearDropIndicator()
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard dragState.draggedTabId != nil || dragState.dropIndicator != nil else { return }
            let reason = SidebarDragLifecycleNotification().reason(from: notification)
#if DEBUG
            cmuxDebugLog("sidebar.dragClear tab=\(debugShortSidebarTabId(dragState.draggedTabId)) reason=\(reason)")
#endif
            dragState.clearDrag()
        }
        .onChange(of: tabManager.tabs.map(\.id)) { tabIds in
            guard let frozenTabId = frozenShortcutHintsTabId,
                  !tabIds.contains(frozenTabId) else { return }
            frozenShortcutHintsTabId = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workspaceScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        let scrollInsets = SidebarWorkspaceScrollInsets.workspaceList
        return GeometryReader { geometryProxy in
            let contentMinHeight = SidebarWorkspaceScrollLayout.contentMinHeight(
                viewportHeight: geometryProxy.size.height,
                insets: scrollInsets
            )
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    workspaceScrollContent(
                        renderContext: renderContext,
                        minHeight: contentMinHeight
                    )
                }
                .background(
                    SidebarScrollViewResolver { scrollView in
                        configureSidebarScrollView(scrollView)
                        dragAutoScrollController.attach(scrollView: scrollView)
                    }
                    .frame(width: 0, height: 0)
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: scrollInsets.top)
                        .allowsHitTesting(false)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: scrollInsets.bottom)
                        .allowsHitTesting(false)
                }
                .mask(
                    SidebarWorkspaceScrollEdgeFadeMask(
                        topHeight: sidebarTopScrimHeight,
                        bottomHeight: sidebarBottomScrimHeight
                    )
                )
                .overlay(alignment: .top) {
                    // The sidebar top strip remains draggable and handles
                    // double-clicks with the standard titlebar action.
                    WindowDragHandleView()
                        .frame(height: sidebarTitlebarInteractionHeight)
                        .background(TitlebarDoubleClickMonitorView())
                }
                .overlay(alignment: .topLeading) {
                    if isMinimalMode {
                        HiddenTitlebarSidebarControlsView(
                            notificationStore: notificationStore,
                            onToggleSidebar: onToggleSidebar,
                            onToggleNotifications: { anchorView in
                                AppDelegate.shared?.toggleNotificationsPopover(
                                    animated: true,
                                    anchorView: anchorView
                                )
                            },
                            onNewTab: onNewTab,
                            onFocusHistoryBack: {
                                if !tabManager.navigateBack() {
                                    NSSound.beep()
                                }
                            },
                            onFocusHistoryForward: {
                                if !tabManager.navigateForward() {
                                    NSSound.beep()
                                }
                            }
                        )
                            .padding(
                                .leading,
                                CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset)
                            )
                            .padding(
                                .top,
                                minimalModeSidebarTitlebarControlsTopPadding
                            )
                    }
                }
                .overlay(alignment: .top) {
                    workspaceReorderDropOverlay(
                        renderContext: renderContext,
                        pointOffset: CGSize(width: 0, height: -scrollInsets.top)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: scrollInsets.top)
                }
                .background(Color.clear)
                .modifier(ClearScrollBackground())
                .onAppear {
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                }
                .onChange(of: tabManager.selectedTabId) { _, _ in
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                }
                .onChange(of: renderContext.workspaceIds) { oldWorkspaceIds, newWorkspaceIds in
                    guard shouldRequestSelectedWorkspaceScrollAfterWorkspaceIdsChange(
                        from: oldWorkspaceIds,
                        to: newWorkspaceIds
                    ) else {
                        flushPendingSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                        return
                    }
                    requestSelectedWorkspaceScroll(scrollProxy, renderContext: renderContext)
                }
                .onReceive(NotificationCenter.default.publisher(for: .workspaceOrderDidChange)) { notification in
                    requestSelectedWorkspaceScrollAfterWorkspaceOrderChange(notification)
                }
                .onReceive(NotificationCenter.default.publisher(for: .workspaceCurrentDirectoryDidChange)) { _ in
                    // Drive a revision counter that the group-header resolver
                    // reads. Forces SwiftUI to re-invoke `cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd:)`
                    // when the anchor's cwd changes while the anchor is not
                    // the selected workspace — otherwise group color/icon/menu
                    // and `+` placement reflect the previous cwd until some
                    // unrelated sidebar event fires.
                    anchorCwdRevision &+= 1
                }
                .onReceive(NotificationCenter.default.publisher(for: SidebarMultiSelectionDidHideEvent.notificationName)) { notification in
                    // Group collapse hides some workspaces without changing
                    // focus or wiping the rest of the multi-selection. Strip
                    // only the hidden ids; if focus moved, make sure the new
                    // focused id is still represented.
                    guard let model = notification.object as? SidebarMultiSelectionModel,
                          model === tabManager.sidebarMultiSelection,
                          let event = SidebarMultiSelectionDidHideEvent(notification) else { return }
                    var next = selectedTabIds.subtracting(event.hiddenWorkspaceIds)
                    if let movedFocus = event.focusedWorkspaceId {
                        next.insert(movedFocus)
                        if let index = tabManager.tabs.firstIndex(where: { $0.id == movedFocus }) {
                            lastSidebarSelectionIndex = index
                        }
                    }
                    if next != selectedTabIds {
                        selectedTabIds = next
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: SidebarMultiSelectionShouldCollapseEvent.notificationName)) { notification in
                    // Keyboard nav (selectNextTab/selectPreviousTab) posts
                    // this so any stale Shift-click range in the sidebar's
                    // SwiftUI selectedTabIds collapses to just the newly-
                    // focused workspace. Without this, batch context-menu /
                    // shortcut actions would still target the stale range.
                    guard let model = notification.object as? SidebarMultiSelectionModel,
                          model === tabManager.sidebarMultiSelection,
                          let event = SidebarMultiSelectionShouldCollapseEvent(notification) else { return }
                    let focusedId = event.focusedWorkspaceId
                    let next: Set<UUID> = tabManager.tabs.contains(where: { $0.id == focusedId }) ? [focusedId] : []
                    if selectedTabIds != next {
                        selectedTabIds = next
                    }
                    if let index = tabManager.tabs.firstIndex(where: { $0.id == focusedId }) {
                        lastSidebarSelectionIndex = index
                    }
                }
            }
        }
    }

    // Applies one stable overlay/autohide scroller config and never toggles it.
    // Toggling `hasVerticalScroller`/style from SwiftUI re-renders (constant
    // while agents update rows) re-flashes the overlay knob so it never reaches
    // its idle fade; a stable config lets AppKit own appear/scroll/fade and the
    // finite empty-area height keeps it hidden when content fits (#3241).
    private func configureSidebarScrollView(_ scrollView: NSScrollView?) {
        guard let scrollView else { return }
        scrollView.applySidebarOverlayScrollerConfiguration()
    }

    private func extensionSidebarScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        extensionSidebarScrollAreaContent(renderContext: renderContext)
            .onAppear {
                refreshExtensionSidebarObservationPublishers(tabs: renderContext.tabs)
            }
            .onChange(of: renderContext.workspaceIds) { _, _ in
                refreshExtensionSidebarObservationPublishers(tabs: renderContext.tabs)
            }
            .onDisappear {
                clearExtensionSidebarObservationPublishers()
            }
    }

    @ViewBuilder
    private func extensionSidebarScrollAreaContent(renderContext: WorkspaceListRenderContext) -> some View {
        if effectiveExtensionSidebarProviderId == CmuxExtensionSidebarSelection.hostedExtensionsProviderId {
            CMUXInstalledExtensionSidebarHostView(
                snapshotProvider: { cmuxSidebarSnapshotForCurrentTabs() },
                snapshotUpdateToken: extensionSidebarUpdateToken,
                actionHandler: { handleCMUXSidebarExtensionAction($0) },
                onUseDefaultSidebar: {
                    CmuxExtensionSidebarSelection.setProviderId(CmuxSidebarProviderDescriptor.defaultWorkspacesID)
                }
            )
            .onReceive(extensionSidebarImmediateObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(extensionSidebarDebouncedObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            // Fade the extension's content out at the bottom so it dissolves behind the
            // sidebar footer instead of overlapping it sharply, matching the default
            // workspace sidebar's bottom scrim. Top stays sharp so the control strip
            // remains crisp.
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: 0,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else if effectiveExtensionSidebarProviderId.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix),
                  let customSidebarURL = CmuxExtensionSidebarSelection.customSidebarFileURL(forProviderId: effectiveExtensionSidebarProviderId) {
            // Periodic tick so the custom sidebar re-renders live (clock,
            // countdowns, and refreshed workspace/data context), mirroring the
            // default sidebar's TimelineView. No banned timers involved.
            // The surface mounts the in-process renderer by default (native
            // hover/focus/keyboard, same-frame resize); the
            // `customSidebars.renderer` setting switches it to the
            // out-of-process worker for untrusted sources (no file-derived
            // view code runs in the host). The @LiveSetting's initial value
            // lags one store round-trip on remount, so a non-default choice
            // can mount the other renderer for one tick before flipping;
            // harmless (the host shuts the short-lived client down on
            // unmount).
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                CustomSidebarSurface(
                    fileURL: customSidebarURL,
                    dataContext: customSidebarDataContext(now: timeline.date),
                    dispatch: makeCmuxSidebarActionDispatch(),
                    contentInsets: CustomSidebarContentInsets(
                        top: SidebarWorkspaceScrollInsets.workspaceList.top,
                        bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
                    ),
                    rendersInProcess: customSidebarRenderer == .inProcess,
                    client: $sidebarRenderWorkerClient
                )
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let model = extensionSidebarRenderModel(renderContext: renderContext, now: timeline.date)
                extensionSidebarTimelineContent(renderContext: renderContext, model: model, now: timeline.date)
            }
        }
    }

    private func extensionSidebarTimelineContent(
        renderContext: WorkspaceListRenderContext,
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        GeometryReader { geometryProxy in
            ScrollView {
                if model.presentation == .browserStack {
                    extensionBrowserStackSidebar(model: model, now: now)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                                viewportHeight: geometryProxy.size.height,
                                insets: SidebarWorkspaceScrollInsets.workspaceList
                            ),
                            alignment: .topLeading
                        )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections) { section in
                            extensionSidebarSection(section, providerId: model.providerId, now: now)
                        }

                        SidebarEmptyArea(
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            topDropIndicatorVisible: emptyAreaTopDropIndicatorVisible(),
                            tabDropDelegate: emptyAreaTabDropDelegate(renderContext: renderContext),
                            bonsplitDropIndicator: dropIndicatorBinding
                        )
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .padding(.top, SidebarWorkspaceListMetrics.rowVerticalPadding)
                    .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: SidebarWorkspaceScrollInsets.workspaceList
                        ),
                        alignment: .topLeading
                    )
                }
            }
            .background(
                SidebarScrollViewResolver { scrollView in
                    configureSidebarScrollView(scrollView)
                    dragAutoScrollController.attach(scrollView: scrollView)
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.top)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.bottom)
                    .allowsHitTesting(false)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                WindowDragHandleView()
                    .frame(height: sidebarTitlebarInteractionHeight)
                    .background(TitlebarDoubleClickMonitorView())
            }
            .overlay(alignment: .topLeading) {
                if isMinimalMode {
                    HiddenTitlebarSidebarControlsView(
                        notificationStore: notificationStore,
                        onToggleSidebar: onToggleSidebar,
                        onToggleNotifications: { anchorView in
                            AppDelegate.shared?.toggleNotificationsPopover(
                                animated: true,
                                anchorView: anchorView
                            )
                        },
                        onNewTab: onNewTab,
                        onFocusHistoryBack: {
                            if !tabManager.navigateBack() {
                                NSSound.beep()
                            }
                        },
                        onFocusHistoryForward: {
                            if !tabManager.navigateForward() {
                                NSSound.beep()
                            }
                        }
                    )
                    .padding(
                        .leading,
                        CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset)
                    )
                    .padding(
                        .top,
                        minimalModeSidebarTitlebarControlsTopPadding
                    )
                }
            }
            .background(Color.clear)
            .modifier(ClearScrollBackground())
            .onReceive(extensionSidebarImmediateObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(extensionSidebarDebouncedObservationPublisher) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: BrowserStackSidebar.stateDidLoadNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
        }
    }

    private func refreshExtensionSidebarSnapshot() {
        extensionSidebarUpdateToken &+= 1
    }

    private func clearExtensionSidebarObservationPublishers() {
        extensionSidebarObservationWorkspaceIds = []
        extensionSidebarObservationPublishersBuilt = false
        extensionSidebarImmediateObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
        extensionSidebarDebouncedObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
    }

    private func refreshExtensionSidebarObservationPublishers(tabs: [Workspace]) {
        let workspaceIds = tabs.map(\.id)
        guard !extensionSidebarObservationPublishersBuilt ||
              workspaceIds != extensionSidebarObservationWorkspaceIds
        else { return }

        extensionSidebarObservationPublishersBuilt = true
        extensionSidebarObservationWorkspaceIds = workspaceIds

        guard !tabs.isEmpty else {
            extensionSidebarImmediateObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
            extensionSidebarDebouncedObservationPublisher = Empty<Void, Never>().eraseToAnyPublisher()
            return
        }

        extensionSidebarImmediateObservationPublisher = Publishers.MergeMany(
            tabs.map { $0.sidebarImmediateObservationPublisher }
        )
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
        extensionSidebarDebouncedObservationPublisher = Publishers.MergeMany(
            tabs.map { $0.sidebarObservationPublisher }
        )
        .receive(on: RunLoop.main)
        .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: RunLoop.main)
        .eraseToAnyPublisher()
    }

    private func extensionSidebarRenderModel(
        renderContext: WorkspaceListRenderContext,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let _ = extensionSidebarUpdateToken
        let snapshot = extensionSidebarSnapshot(renderContext: renderContext)
        return extensionSidebarRenderModel(snapshot: snapshot, now: now)
    }

    private func extensionSidebarRenderModel(
        snapshot: CmuxSidebarProviderSnapshot,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        // Look up the provider directly by the effective id instead of round-
        // tripping through `descriptor(for:)`, which rebuilds the full
        // `descriptors` list (SettingCatalog + custom-sidebars directory scan)
        // on every TimelineView tick. See issue #5970.
        let providerId = effectiveExtensionSidebarProviderId
        if let provider = CmuxExtensionSidebarSelection.provider(for: providerId) {
            let context = CmuxSidebarProviderRenderContext(now: now)
            if let contextualProvider = provider as? any CmuxContextualSidebarProvider {
                return contextualProvider.render(snapshot: snapshot, context: context)
            }
            return provider.render(snapshot: snapshot)
        }
        return CmuxSidebarProviderRenderModel(
            providerId: providerId,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    private func extensionSidebarSnapshot(
        renderContext: WorkspaceListRenderContext
    ) -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: renderContext.tabs)
    }

    private func extensionSidebarSnapshotForCurrentTabs() -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: tabManager.tabs)
    }

    private func cmuxSidebarSnapshotForCurrentTabs() -> CmuxSidebarSnapshot {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        return CmuxSidebarSnapshot(
            sequence: snapshot.sequence,
            windowID: snapshot.windowId,
            selectedWorkspaceID: snapshot.selectedWorkspaceId,
            workspaces: snapshot.workspaces.map { workspace in
                CmuxSidebarWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    detail: workspace.customDescription,
                    isPinned: workspace.isPinned,
                    rootPath: workspace.rootPath,
                    projectRootPath: workspace.projectRootPath,
                    gitBranch: workspace.branchSummary,
	                    unreadCount: workspace.unreadCount,
	                    latestNotification: workspace.latestNotificationText,
	                    listeningPorts: workspace.listeningPorts,
	                    pullRequestURLs: workspace.pullRequestURLs,
	                    surfaces: cmuxSidebarSurfaces(for: workspace)
	                )
	            }
	        )
	    }

    private func cmuxSidebarSurfaces(for workspace: CmuxSidebarProviderWorkspace) -> [CmuxSidebarSurface] {
        guard let liveWorkspace = tabManager.tabs.first(where: { $0.id == workspace.id }) else { return [] }
        return liveWorkspace.sidebarOrderedPanelIds().compactMap { panelId in
            guard let panel = liveWorkspace.panels[panelId] else { return nil }
            return CmuxSidebarSurface(
                id: panelId,
                title: liveWorkspace.panelTitle(panelId: panelId) ?? panel.displayTitle,
                kind: cmuxSidebarSurfaceKind(for: panel.panelType),
                isFocused: liveWorkspace.focusedPanelId == panelId,
                isPinned: liveWorkspace.isPanelPinned(panelId),
                unreadCount: liveWorkspace.manualUnreadPanelIds.contains(panelId) ? 1 : 0,
                workingDirectory: liveWorkspace.panelDirectories[panelId]
            )
        }
    }
    private func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .customSidebar:
            return .unknown
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .unknown
        }
    }

    private func handleCMUXSidebarExtensionAction(
        _ action: CmuxSidebarAction
    ) -> CmuxSidebarActionResult {
        switch action {
        case .createWorkspace(let title, let workingDirectory, let select):
            let workspace = tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                inheritWorkingDirectory: workingDirectory == nil,
                select: select
            )
            return CmuxSidebarActionResult(accepted: true, message: workspace.id.uuidString)

        case .selectWorkspace(let workspaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found")
                )
            }
            tabManager.selectWorkspace(workspace)
            return .accepted

        case .closeWorkspace(let workspaceId):
            guard tabManager.closeWorkspaceWithConfirmation(tabId: workspaceId) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.closeRejected", defaultValue: "Workspace could not be closed")
                )
            }
            return .accepted

        case .selectNextWorkspace:
            tabManager.selectNextTab()
            return .accepted

        case .selectPreviousWorkspace:
            tabManager.selectPreviousTab()
            return .accepted

        case .createTerminalSurface(let workspaceId):
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panel = workspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
            if panel == nil, workspace.isRemoteTmuxMirror {
                // Routed to the remote as a tmux `new-window`; the tab arrives
                // asynchronously via the mirror, so this is success, not failure.
                return CmuxSidebarActionResult(
                    accepted: true,
                    message: String(localized: "sidebar.extensions.action.remoteTmuxWindowRequested", defaultValue: "Remote tmux window requested")
                )
            }
            return panel.map { CmuxSidebarActionResult(accepted: true, message: $0.id.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .createBrowserSurface(let workspaceId, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panelId = tabManager.createBrowserSplit(direction: .right, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .selectSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.selectWorkspace(workspace)
            workspace.focusPanel(surfaceId)
            return .accepted

        case .selectNextSurface:
            tabManager.selectNextSurface()
            return .accepted

        case .selectPreviousSurface:
            tabManager.selectPreviousSurface()
            return .accepted

        case .closeSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            guard workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: surfaceId)
            return .accepted

        case .splitTerminal(let workspaceId, let surfaceId, let direction):
            guard let splitDirection = splitDirection(from: direction),
                  let panelId = tabManager.createSplit(tabId: workspaceId, surfaceId: surfaceId, direction: splitDirection) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            return CmuxSidebarActionResult(accepted: true, message: panelId.uuidString)

        case .splitBrowser(let workspaceId, let surfaceId, let direction, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let splitDirection = splitDirection(from: direction),
                  let tab = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  tab.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            tabManager.selectWorkspace(tab)
            tab.focusPanel(surfaceId)
            let panelId = tabManager.createBrowserSplit(direction: splitDirection, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .toggleSurfaceZoom(let workspaceId, let surfaceId):
            guard tabManager.toggleSplitZoom(tabId: workspaceId, surfaceId: surfaceId) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            return .accepted

        case .openURL(let urlString):
            guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString),
                  NSWorkspace.shared.open(url) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened")
                )
            }
            return .accepted
        }
    }

    private func cmuxSidebarExtensionOptionalHTTPURL(from urlString: String?) -> (url: URL?, accepted: Bool) {
        guard let urlString, !urlString.isEmpty else {
            return (nil, true)
        }
        guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString) else {
            return (nil, false)
        }
        return (url, true)
    }

    private func cmuxSidebarExtensionRequiredHTTPURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private func splitDirection(from direction: CmuxSidebarSplitDirection) -> SplitDirection? {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private func extensionSidebarSnapshot(workspaces: [Workspace]) -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(
            sequence: UInt64(max(0, CmuxEventBus.shared.latestSequence)),
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaces: workspaces.map(extensionWorkspaceSnapshot(for:)),
            windowId: windowId
        )
    }

    private func extensionWorkspaceSnapshot(for workspace: Workspace) -> CmuxSidebarProviderWorkspace {
        let rootPath = extensionSidebarRootPath(for: workspace)
        return CmuxSidebarProviderWorkspace(
            id: workspace.id,
            title: workspace.title,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            rootPath: rootPath,
            projectRootPath: workspace.extensionSidebarProjectRootPath,
            branchSummary: workspace.sidebarGitBranchesInDisplayOrder().first?.branch,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionState: workspace.remoteConnectionState.rawValue,
            unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id),
            latestNotificationText: sidebarUnread.latestNotificationText(forWorkspaceId: workspace.id),
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                CmuxSidebarProviderGitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    private func extensionSidebarRootPath(for workspace: Workspace) -> String? {
        workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func extensionBrowserStackSidebar(
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        let rows = model.sections.flatMap(\.rows)
        let tileRows = model.sections.first { $0.id == "tiles" }?.rows ?? Array(rows.prefix(3))
        let looseRows = model.sections.first { $0.id == "loose" }?.rows ?? Array(rows.dropFirst(3).prefix(5))
        let groupedSections = model.sections.filter { $0.id != "tiles" && $0.id != "loose" && !$0.rows.isEmpty }
        let dropRows = extensionBrowserStackDropRows(for: model)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(stride(from: 0, to: tileRows.count, by: 3)), id: \.self) { rowStart in
                    HStack(spacing: 8) {
                        ForEach(Array(tileRows[rowStart..<min(rowStart + 3, tileRows.count)].enumerated()), id: \.element.id) { offset, row in
                            let index = rowStart + offset
                            extensionBrowserStackTile(
                                row: row,
                                isSelected: row.workspaceId == tabManager.selectedTabId
                                    || (tabManager.selectedTabId == nil && index == 0),
                                dropRows: dropRows
                            )
                        }
                        if tileRows.count - rowStart < 3 {
                            ForEach(0..<(3 - (tileRows.count - rowStart)), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(looseRows) { row in
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                }
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupedSections) { section in
                    extensionBrowserStackGroup(section: section, now: now, dropRows: dropRows)
                }
            }

            Button(action: onNewTab) {
                HStack(spacing: 9) {
                    CmuxSystemSymbolImage(magnified: "plus", pointSize: 15, weight: .regular)
                        .frame(width: 22, height: 22)
                    Text(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))
                        .cmuxFont(size: 13, weight: .regular)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .safeHelp(String(localized: "sidebar.browserStack.newTab", defaultValue: "New Tab"))

            ExtensionSidebarBrowserStackEmptyArea(
                rowSpacing: tabRowSpacing,
                orderedRows: dropRows,
                dragAutoScrollController: dragAutoScrollController,
                draggedTabId: draggedTabIdBinding,
                dropIndicator: dropIndicatorBinding,
                onNewTab: onNewTab,
                onMove: { move in
                    handleExtensionSidebarMutation(.moveWorkspace(move))
                }
            )
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
    }

    private func extensionBrowserStackGroup(
        section: CmuxSidebarProviderSection,
        now: Date,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                CmuxSystemSymbolImage(magnified: "folder.fill", pointSize: 14, weight: .regular)
                    .foregroundColor(.secondary)
                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .cmuxFont(size: 13, weight: .semibold)
                    .foregroundColor(.primary.opacity(0.86))
                    .lineLimit(1)
                CmuxSystemSymbolImage(magnified: "chevron.down", pointSize: 11, weight: .medium)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.rows) { row in
                    extensionBrowserStackRow(
                        row: row,
                        now: now,
                        compact: true,
                        isSelected: row.workspaceId == tabManager.selectedTabId,
                        dropRows: dropRows
                    )
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
    }

    private func extensionBrowserStackTile(
        row: CmuxSidebarProviderRow,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = 54

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            extensionBrowserStackIcon(row.leadingIcon, size: 28)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            isSelected
                                ? Color(red: 0.44, green: 0.29, blue: 0.23).opacity(0.9)
                                : Color.primary.opacity(0.10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    isSelected ? Color.red.opacity(0.85) : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .safeHelp(row.title)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .onDrag {
            dragState.beginDragging(tabId: row.workspaceId)
            return SidebarTabDragPayload.provider(for: row.workspaceId)
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func extensionBrowserStackRow(
        row: CmuxSidebarProviderRow,
        now: Date,
        compact: Bool = false,
        isSelected: Bool,
        dropRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> some View {
        let targetRowHeight: CGFloat = compact ? 34 : 38

        return Button {
            selectExtensionSidebarWorkspace(row.workspaceId)
        } label: {
            HStack(spacing: 9) {
                extensionBrowserStackIcon(row.leadingIcon, size: compact ? 22 : 24)
                Text(row.title)
                    .cmuxFont(size: compact ? 12.5 : 13, weight: .medium)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let trailing = extensionSidebarRenderedText(row.trailingText, now: now) {
                    Text(trailing)
                        .cmuxFont(size: 11, weight: .regular)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(isSelected ? cmuxAccentColor().opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(dragState.draggedTabId == row.workspaceId ? 0.55 : 1)
        .onDrag {
            dragState.beginDragging(tabId: row.workspaceId)
            return SidebarTabDragPayload.provider(for: row.workspaceId)
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackDropDelegate(
            targetWorkspaceId: row.workspaceId,
            orderedRows: dropRows,
            draggedTabId: draggedTabIdBinding,
            targetRowHeight: targetRowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: dropIndicatorBinding,
            onMove: { move in
                handleExtensionSidebarMutation(.moveWorkspace(move))
            }
        ))
        .overlay(alignment: .top) {
            extensionBrowserStackDropIndicator(row: row, edge: .top)
        }
        .overlay(alignment: .bottom) {
            extensionBrowserStackDropIndicator(row: row, edge: .bottom)
        }
        .contextMenu {
            extensionBrowserStackReorderMenu(row: row)
        }
        .accessibilityHint(Text(String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
        )))
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        .accessibilityAction(named: Text(String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down"))) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackDropIndicator(
        row: CmuxSidebarProviderRow,
        edge: SidebarDropEdge
    ) -> some View {
        if dragState.dropIndicator == SidebarDropIndicator(tabId: row.workspaceId, edge: edge) {
            Rectangle()
                .fill(cmuxAccentColor())
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func extensionBrowserStackReorderMenu(row: CmuxSidebarProviderRow) -> some View {
        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: -1)
        }
        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveExtensionBrowserStackWorkspace(row.workspaceId, by: 1)
        }
    }

    private func moveExtensionBrowserStackWorkspace(_ workspaceId: UUID, by delta: Int) {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        let model = extensionSidebarRenderModel(snapshot: snapshot, now: Date())
        let dropRows = extensionBrowserStackDropRows(for: model)
        guard let currentIndex = dropRows.firstIndex(where: { $0.workspaceId == workspaceId }) else { return }
        let targetIndex = min(max(currentIndex + delta, 0), dropRows.count - 1)
        guard targetIndex != currentIndex else { return }
        let insertionPosition = delta > 0 ? targetIndex + 1 : targetIndex
        guard let move = extensionBrowserStackMove(
            workspaceId: workspaceId,
            insertionPosition: insertionPosition,
            orderedRows: dropRows
        ) else {
            NSSound.beep()
            return
        }
        guard handleExtensionSidebarMutation(.moveWorkspace(move)) else {
            NSSound.beep()
            return
        }
    }

    private func handleExtensionSidebarMutation(_ mutation: CmuxSidebarProviderMutation) -> Bool {
        let descriptor = CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId)
        guard let provider = CmuxExtensionSidebarSelection.provider(for: descriptor.id) as? any CmuxMutableSidebarProvider else {
            return false
        }
        do {
            let result = try provider.handle(mutation, snapshot: extensionSidebarSnapshotForCurrentTabs())
            if result.ok {
                refreshExtensionSidebarSnapshot()
            }
            return result.ok
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.mutation.failed provider=\(descriptor.id) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func extensionBrowserStackDropRows(
        for model: CmuxSidebarProviderRenderModel
    ) -> [ExtensionSidebarBrowserStackDropRow] {
        model.sections.flatMap { section in
            section.rows.map { row in
                ExtensionSidebarBrowserStackDropRow(
                    workspaceId: row.workspaceId,
                    sectionId: section.id
                )
            }
        }
    }

    private func extensionBrowserStackMove(
        workspaceId: UUID,
        insertionPosition: Int,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
            draggedWorkspaceId: workspaceId,
            insertionPosition: insertionPosition
        )
    }

    private func extensionSidebarWorkspaceSnapshotsById(
        for rows: [CmuxSidebarProviderRow]
    ) -> [UUID: CmuxSidebarProviderWorkspace] {
        var snapshotsById: [UUID: CmuxSidebarProviderWorkspace] = [:]
        for row in rows where snapshotsById[row.workspaceId] == nil {
            snapshotsById[row.workspaceId] = extensionWorkspaceSnapshot(for: row.workspaceId)
        }
        return snapshotsById
    }

    private func extensionBrowserStackIcon(
        _ icon: CmuxSidebarProviderIcon?,
        size: CGFloat
    ) -> some View {
        let shape = icon?.shape ?? .circle
        let foreground = extensionSidebarColor(hex: icon?.foregroundColorHex, fallback: .primary)
        let background = extensionSidebarColor(hex: icon?.backgroundColorHex, fallback: Color.primary.opacity(0.16))
        return ZStack {
            if shape == .circle {
                Circle().fill(background)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(background)
            }
            if let systemImageName = icon?.systemImageName {
                CmuxSystemSymbolImage(magnified: systemImageName, pointSize: size * 0.58, weight: .semibold)
                    .foregroundColor(foreground)
            } else {
                Text(icon?.text ?? ".")
                    .cmuxFont(size: size * 0.58, weight: .bold)
                    .foregroundColor(foreground)
            }
        }
        .frame(width: size, height: size)
    }

    private func extensionSidebarRenderedText(_ text: CmuxSidebarProviderText?, now: Date) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: now)
        }
    }

    private func extensionSidebarColor(hex: String?, fallback: Color) -> Color {
        guard let hex else { return fallback }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 else { return fallback }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    @ViewBuilder
    private func extensionSidebarSection(
        _ section: CmuxSidebarProviderSection,
        providerId: String,
        now: Date
    ) -> some View {
        let isCollapsed = collapsedExtensionSidebarSectionIds.contains(section.id)
        let canCreateWorktree = section.treeSection.projectRootPath != nil
        let selectedWorkspaceId = tabManager.selectedTabId
        let workspaceSnapshotsById = extensionSidebarWorkspaceSnapshotsById(for: section.rows)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(Self.extensionSidebarDisclosureAnimation) {
                        if isCollapsed {
                            collapsedExtensionSidebarSectionIds.remove(section.id)
                        } else {
                            collapsedExtensionSidebarSectionIds.insert(section.id)
                        }
                    }
                } label: {
                    CmuxSystemSymbolImage(magnified: isCollapsed ? "folder" : "folder.fill", pointSize: 13, weight: .regular)
                        .offset(y: -0.5)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.toggleSection", defaultValue: "Toggle section"))

                Text(extensionSidebarTreeSectionTitle(section.treeSection))
                    .cmuxFont(size: 12, weight: .regular)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if canCreateWorktree {
                    let worktreeButtonSymbol = extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id)
                        ? "clock"
                        : "plus"
                    Button {
                        createExtensionWorktreeWorkspace(for: section.treeSection)
                    } label: {
                        CmuxSystemSymbolImage(magnified: worktreeButtonSymbol, pointSize: 11, weight: .regular)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id))
                    .safeHelp(String(localized: "sidebar.extension.createWorktree", defaultValue: "Create worktree"))
                    .accessibilityIdentifier("ExtensionSidebarCreateWorktreeButton.\(section.id)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.rows) { row in
                        CmuxExtensionSidebarWorkspaceRowView(
                            row: row,
                            workspace: workspaceSnapshotsById[row.workspaceId],
                            providerId: providerId,
                            relativeNow: now,
                            isSelected: row.workspaceId == selectedWorkspaceId,
                            onSelect: selectExtensionSidebarWorkspace,
                            onOpenWindow: CmuxExtensionSidebarInspectorWindowController.show
                        )
                        .id(row.id)
                        .accessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func extensionWorkspaceSnapshot(for workspaceId: UUID) -> CmuxSidebarProviderWorkspace? {
        tabManager.tabs.first { $0.id == workspaceId }.map(extensionWorkspaceSnapshot(for:))
    }

    private func extensionSidebarTreeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        if let titleText = section.titleText {
            return CmuxExtensionSidebarSelection.localizedText(titleText)
        }
        return section.title
    }

    private func selectExtensionSidebarWorkspace(_ workspaceId: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        selection = .tabs
        selectedTabIds = [workspaceId]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }
        tabManager.selectWorkspace(workspace)
    }

    private func createExtensionWorktreeWorkspace(for section: CmuxSidebarProviderTreeSection) {
        guard let projectRootPath = section.projectRootPath,
              !extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) else {
            return
        }

        extensionSidebarWorktreeCreationInFlightSectionIds.insert(section.id)
        Task {
            do {
                let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRootPath)
                let spawnArgs = result.workspaceSpawnArgs()
                tabManager.addWorkspace(
                    title: spawnArgs.title,
                    workingDirectory: spawnArgs.workingDirectory,
                    initialTerminalInput: spawnArgs.initialTerminalInput,
                    inheritWorkingDirectory: spawnArgs.inheritWorkingDirectory,
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: spawnArgs.initialTerminalInput == nil
                )
            } catch {
                NSSound.beep()
#if DEBUG
                cmuxDebugLog("extensionSidebar.worktree.failed project=\(projectRootPath) error=\(error.localizedDescription)")
#endif
            }
            extensionSidebarWorktreeCreationInFlightSectionIds.remove(section.id)
        }
    }

    private func workspaceScrollContent(
        renderContext: WorkspaceListRenderContext,
        minHeight: CGFloat
    ) -> some View {
        let shouldCollectWorkspaceDropTargets = SidebarDropPlanner().shouldCollectWorkspaceDropTargets(
            draggedTabId: dragState.draggedTabId,
            isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropTargetCollectionActive ||
                isWorkspaceReorderDropTargetCollectionActive
        )
        // Rows stay lazy + pinned top; `.frame(minHeight:)` fills the viewport
        // (#3241) or scrolls without measuring the LazyVStack. The prior
        // SidebarRowsFillLayout measured it (`sizeThatFits(height: nil)`) every
        // pass, realizing all rows and re-livelocking at scale (#2586 / #5764 /
        // #5845; regressed by #6033). Drop/tap = background; indicator on rows.
        let content = workspaceRows(
            renderContext: renderContext,
            shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
        )
            .overlay(alignment: .bottom) {
                if emptyAreaTopDropIndicatorVisible() {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: tabRowSpacing / 2)
                }
            }
            // Neutralize ALL end-of-list empty-area interactions over the rows
            // block (2pt gaps, row padding, and the entire list when it
            // overflows) so none fall through to SidebarEmptyArea behind:
            // workspace-reorder drops, Bonsplit new-workspace drops, and the
            // double-tap-to-create gesture. Sized to the rows, so only the
            // genuine blank area below the last row stays interactive. This is
            // the measurement-free equivalent of physically placing the empty
            // area below the rows; doing that requires asking the LazyVStack for
            // its height, which realizes every row each layout pass and is the
            // livelock this change removes. Per-row delegates render in front
            // and still win over their own rows.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {}
                    .onDrop(of: SidebarTabDragPayload.dropContentTypes, isTargeted: nil) { _ in false }
                    .onDrop(of: BonsplitTabDragPayload.dropContentTypes, isTargeted: nil) { _ in false }
            }
            .frame(minHeight: minHeight, alignment: .top)
            .background(alignment: .top) {
                SidebarEmptyArea(
                    rowSpacing: tabRowSpacing,
                    selection: $selection,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dragAutoScrollController: dragAutoScrollController,
                    topDropIndicatorVisible: false,
                    bonsplitDropIndicator: dropIndicatorBinding,
                    expandsVertically: true
                )
            }

        return rowsWithGatedDropTargetReader(
            rows: content,
            renderContext: renderContext,
            shouldCollect: shouldCollectWorkspaceDropTargets
        )
        .overlay {
            workspaceReorderDropOverlay(renderContext: renderContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            bonsplitWorkspaceDropOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func workspaceRows(
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let renderItems = renderContext.workspaceRenderItems
        // LazyVStack is safe here because `dragState` is @Observable:
        // drag mutations at 60fps invalidate only the rows/overlays that
        // read them, never this sidebar body. See SidebarDragState and
        // https://github.com/manaflow-ai/cmux/issues/2586.
        LazyVStack(spacing: tabRowSpacing) {
            ForEach(renderItems, id: \.id) { item in
                switch item {
                case .groupHeader(let group, let memberWorkspaceIds):
                    sidebarWorkspaceGroupHeader(
                        group: group,
                        memberWorkspaceIds: memberWorkspaceIds,
                        renderContext: renderContext,
                        shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets, showModifierHoldHints: showModifierHoldHints
                    )
                case .workspace(let tab):
                    workspaceRow(
                        tab,
                        renderContext: renderContext,
                        shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
                    )
                }
            }
        }
        .padding(.vertical, SidebarWorkspaceListMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No whole-content height measurement here: reading the LazyVStack's
        // total height (GeometryReader, or a custom Layout's sizeThatFits) fed a
        // non-converging relayout loop (#2586 / #5764 / #5845). Fill is handled
        // by `.frame(minHeight:)` in workspaceScrollContent.
    }

    /// Conditionally installs the row-frame `overlayPreferenceValue` reader (the part
    /// that defeats `LazyVStack` virtualization) only while a drag is collecting drop
    /// targets. Kept separate from the always-mounted drop-capture overlay so the gate
    /// flip never changes the drop NSView's identity. (#5325 review)
    @ViewBuilder
    private func rowsWithGatedDropTargetReader<Rows: View>(
        rows: Rows,
        renderContext: WorkspaceListRenderContext,
        shouldCollect: Bool
    ) -> some View {
        if shouldCollect {
            rows
                .overlayPreferenceValue(SidebarWorkspaceRowFramePreferenceKey.self) { anchors in
                    GeometryReader { proxy in
                        let workspaceGroupsByAnchor = Dictionary(
                            uniqueKeysWithValues: renderContext.workspaceGroups.map { ($0.anchorWorkspaceId, $0) }
                        )
                        SidebarWorkspaceDropTargetWriters(
                            bonsplitTargetBridge: bonsplitWorkspaceDropTargetBridge,
                            bonsplitTargets: renderContext.tabs.compactMap { tab in
                                guard let anchor = anchors[tab.id] else { return nil }
                                return SidebarDropPlanner.WorkspaceDropTarget(
                                    workspaceId: tab.id,
                                    isPinned: tab.isPinned,
                                    frame: proxy[anchor]
                                )
                            },
                            reorderTargetBridge: workspaceReorderDropTargetBridge,
                            reorderTargets: renderContext.visibleWorkspaceRowIds.compactMap { workspaceId in
                                guard let anchor = anchors[workspaceId],
                                      renderContext.workspaceById[workspaceId] != nil else {
                                    return nil
                                }
                                let group = workspaceGroupsByAnchor[workspaceId]
                                let targetGroupId = group?.id ??
                                    (renderContext.workspaceGroupIdByWorkspaceId[workspaceId] ?? nil)
                                return SidebarWorkspaceReorderDropOverlay.Target(
                                    workspaceId: workspaceId,
                                    groupId: targetGroupId,
                                    isGroupHeader: group != nil,
                                    frame: proxy[anchor]
                                )
                            }
                        )
                    }
                }
        } else {
            rows
        }
    }

    private func bonsplitWorkspaceDropOverlay() -> some View {
        SidebarBonsplitTabWorkspaceDropOverlay(
            currentSelectedTabId: {
                tabManager.selectedTabId
            },
            sidebarIndexForTabId: { workspaceId in
                tabManager.tabs.firstIndex { $0.id == workspaceId }
            },
            moveToExistingWorkspace: { workspaceId, transfer in
                guard let app = AppDelegate.shared else {
                    return false
                }
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.moveBonsplitTab(
                    tabId: transfer.tab.id,
                    toWorkspace: workspaceId,
                    focus: true,
                    focusWindow: true
                )
            },
            moveToNewWorkspace: { insertionIndex, transfer in
                guard let app = AppDelegate.shared,
                      let result = app.moveBonsplitTabToNewWorkspace(
                        tabId: transfer.tab.id,
                        destinationManager: tabManager,
                        focus: true,
                        focusWindow: true,
                        insertionIndexOverride: insertionIndex
                      ) else {
                    return nil
                }
                return result.destinationWorkspaceId
            },
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            dropIndicator: dropIndicatorBinding,
            updateAutoscroll: {
                dragAutoScrollController.updateFromDragLocation()
            },
            setWorkspaceDropTargetCollectionActive: { isActive in
                guard isBonsplitWorkspaceDropTargetCollectionActive != isActive else { return }
                isBonsplitWorkspaceDropTargetCollectionActive = isActive
            },
            isWorkspaceDropTargetCollectionActive: isBonsplitWorkspaceDropTargetCollectionActive,
            targetBridge: bonsplitWorkspaceDropTargetBridge
        )
    }

    private func workspaceReorderDropOverlay(
        renderContext: WorkspaceListRenderContext,
        pointOffset: CGSize = .zero
    ) -> some View {
        SidebarWorkspaceReorderDropOverlay(
            targetBridge: workspaceReorderDropTargetBridge,
            isValidDrag: {
                activateSidebarWorkspaceDragIfNeeded()
            },
            updateDrag: { point, targets in
                updateWorkspaceReorderDrop(point: point, targets: targets, renderContext: renderContext)
            },
            performDrop: { point, targets in
                performWorkspaceReorderDrop(point: point, targets: targets, renderContext: renderContext)
            },
            clearDropIndicator: {
                dragState.clearDropIndicator()
                dragAutoScrollController.stop()
            },
            setWorkspaceDropTargetCollectionActive: { isActive in
                guard isWorkspaceReorderDropTargetCollectionActive != isActive else { return }
                isWorkspaceReorderDropTargetCollectionActive = isActive
            },
            pointOffset: pointOffset
        )
    }

    private func activateSidebarWorkspaceDragIfNeeded() -> Bool {
        if dragState.draggedTabId != nil {
            return true
        }
        guard let foreignId = dragState.currentWorkspaceDragId,
              !tabManager.tabs.contains(where: { $0.id == foreignId }),
              let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: foreignId),
              !sourceManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == foreignId }) else {
            return false
        }
        dragState.foreignDraggedIsPinned = sourceManager.tabs.first { $0.id == foreignId }?.isPinned ?? false
        dragState.draggedTabId = foreignId
        return true
    }

    private func updateWorkspaceReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext
    ) -> Bool {
        guard activateSidebarWorkspaceDragIfNeeded(),
              let plan = workspaceReorderPlan(point: point, targets: targets, renderContext: renderContext) else {
            dragState.clearDropIndicator()
            return false
        }
        dragAutoScrollController.updateFromDragLocation()
        guard dragState.dropIndicator != plan.indicator ||
                dragState.dropIndicatorScope != plan.indicatorScope else {
            return true
        }
        dragState.setDropIndicator(plan.indicator, scope: plan.indicatorScope)
        return true
    }

    private func performWorkspaceReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext
    ) -> Bool {
        defer {
            dragState.clearDrag()
            dragAutoScrollController.stop()
        }
        guard activateSidebarWorkspaceDragIfNeeded(),
              let plan = workspaceReorderPlan(point: point, targets: targets, renderContext: renderContext) else {
            return false
        }
        return performWorkspaceReorderPlan(plan)
    }

    private func workspaceReorderPlan(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let draggedTabId = dragState.draggedTabId else { return nil }
        return SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedTabId,
                foreignDraggedIsPinned: dragState.foreignDraggedIsPinned,
                workspaces: renderContext.tabs.map {
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: $0.id,
                        isPinned: $0.isPinned,
                        groupId: $0.groupId
                    )
                },
                groups: renderContext.workspaceGroups.map {
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: $0.id,
                        anchorWorkspaceId: $0.anchorWorkspaceId,
                        isPinned: $0.isPinned
                    )
                },
                targets: targets.map {
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: $0.workspaceId,
                        groupId: $0.groupId,
                        isGroupHeader: $0.isGroupHeader,
                        frame: $0.frame
                    )
                }
            )
        )
    }

    private func performWorkspaceReorderPlan(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
        switch plan.action {
        case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId):
            let selectionBeforeReorder = selectedTabIds
            let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
                existingAnchorIndex: lastSidebarSelectionIndex,
                liveWorkspaceIds: tabManager.tabs.map(\.id)
            )
            let didReorder = tabManager.reorderSidebarWorkspace(
                tabId: plan.draggedWorkspaceId,
                toIndex: targetIndex,
                isDragOperation: true,
                usesTopLevelRows: usesTopLevelRows,
                explicitGroupId: explicitGroupId
            )
            syncSidebarSelectionAfterWorkspaceReorder(
                preserving: selectionBeforeReorder,
                preferredAnchorWorkspaceId: anchorWorkspaceIdBeforeReorder
            )
            return didReorder
        case .crossWindow(insertionIndex: _, proposedInsertionIndex: let proposedInsertionIndex):
            return performCrossWindowWorkspaceDrop(plan: plan, proposedInsertionIndex: proposedInsertionIndex)
        }
    }

    private func performCrossWindowWorkspaceDrop(
        plan: SidebarWorkspaceReorderDropPlan,
        proposedInsertionIndex: Int
    ) -> Bool {
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: plan.draggedWorkspaceId),
              !sourceManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == plan.draggedWorkspaceId }) else {
            return false
        }

        let sourceSelection = sourceManager.sidebarSelectedWorkspaceIds
        let candidateIds: [UUID]
        if sourceSelection.contains(plan.draggedWorkspaceId), sourceSelection.count > 1 {
            candidateIds = sourceManager.tabs.filter { sourceSelection.contains($0.id) }.map(\.id)
        } else {
            candidateIds = [plan.draggedWorkspaceId]
        }
        let sourceAnchorIds = Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))
        let movingIds = candidateIds.filter { !sourceAnchorIds.contains($0) }
        guard !movingIds.isEmpty else { return false }

        let pinStateById = Dictionary(uniqueKeysWithValues: movingIds.map { id in
            (id, sourceManager.tabs.first { $0.id == id }?.isPinned ?? false)
        })
        var movedIds: [UUID] = []
        for isPinnedTier in [false, true] {
            let tierIds = movingIds.filter { (pinStateById[$0] ?? false) == isPinnedTier }
            guard !tierIds.isEmpty else { continue }
            let topLevelIds = crossWindowTopLevelWorkspaceIds()
            let slot = clampedCrossWindowTopLevelSlot(
                proposedInsertionIndex,
                draggedIsPinned: isPinnedTier,
                topLevelIds: topLevelIds,
                pinnedTopLevelIds: crossWindowTopLevelPinnedWorkspaceIds()
            )
            let base = crossWindowRawInsertIndex(forTopLevelSlot: slot, topLevelIds: topLevelIds)
            var tierOffset = 0
            for workspaceId in tierIds {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspaceId,
                    windowId: destinationWindowId,
                    atIndex: base + tierOffset,
                    focus: false
                ) {
                    movedIds.append(workspaceId)
                    tierOffset += 1
                }
            }
        }

        guard !movedIds.isEmpty else { return false }
        let focusId = movedIds.contains(plan.draggedWorkspaceId) ? plan.draggedWorkspaceId : (movedIds.last ?? plan.draggedWorkspaceId)
        _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: destinationWindowId, focus: true)
        selectedTabIds = Set(movedIds)
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
        return true
    }

    private func clampedCrossWindowTopLevelSlot(
        _ proposedSlot: Int,
        draggedIsPinned: Bool,
        topLevelIds: [UUID],
        pinnedTopLevelIds: Set<UUID>
    ) -> Int {
        let clampedSlot = max(0, min(proposedSlot, topLevelIds.count))
        let pinnedCount = topLevelIds.reduce(into: 0) { count, workspaceId in
            if pinnedTopLevelIds.contains(workspaceId) {
                count += 1
            }
        }
        return draggedIsPinned ? min(clampedSlot, pinnedCount) : max(clampedSlot, pinnedCount)
    }

    private func crossWindowTopLevelWorkspaceIds() -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedWorkspaceIds() -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowRawInsertIndex(forTopLevelSlot slot: Int, topLevelIds: [UUID]) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        return tabManager.tabs.firstIndex { $0.id == topLevelId } ?? tabManager.tabs.count
    }

    private func syncSidebarSelectionAfterWorkspaceReorder(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = tabManager.tabs.map(\.id)
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: tabManager.selectedTabId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    @ViewBuilder
    private func workspaceRow(
        _ tab: Workspace,
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let index = renderContext.tabIndexById[tab.id] ?? 0
        let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
        let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedContextTargetIds
            : [tab.id]
        let remoteContextMenuWorkspaceIds = usesSelectedContextMenuTargets
            ? renderContext.selectedRemoteContextMenuWorkspaceIds
            : (tab.isRemoteWorkspace ? [tab.id] : [])
        let allRemoteContextMenuTargetsConnecting = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsConnecting
            : (
                tab.isRemoteWorkspace &&
                    (tab.remoteConnectionState == .connecting || tab.remoteConnectionState == .reconnecting)
            )
        let allRemoteContextMenuTargetsDisconnected = usesSelectedContextMenuTargets
            ? renderContext.allSelectedRemoteContextMenuTargetsDisconnected
            : (tab.isRemoteWorkspace && tab.remoteConnectionState == .disconnected)
        let contextMenuPinTarget = WorkspaceActionDispatcher.Target(
            workspaceIds: contextMenuWorkspaceIds,
            anchorWorkspaceId: tab.id
        )
        let contextMenuPinState = WorkspaceActionDispatcher.pinState(
            in: renderContext.pinResolutionContext,
            target: contextMenuPinTarget
        )
        let liveUnreadCount = sidebarUnread.unreadCount(forWorkspaceId: tab.id)
        let liveLatestNotificationText: String? = showsSidebarNotificationMessage
            ? sidebarUnread.latestNotificationText(forWorkspaceId: tab.id)
            : nil
        let liveShowsModifierShortcutHints = showModifierHoldHints && modifierKeyMonitor.isModifierPressed
        let resolvedShowsModifierShortcutHints = SidebarShortcutHintFreezePolicy().resolved(
            live: liveShowsModifierShortcutHints,
            currentTabId: tab.id,
            frozenTabId: frozenShortcutHintsTabId,
            frozenValue: frozenShortcutHintsValue
        )
        let onContextMenuAppear: () -> Void = { [tabId = tab.id, snapshot = resolvedShowsModifierShortcutHints] in
            frozenShortcutHintsTabId = tabId
            frozenShortcutHintsValue = snapshot
        }
        let onContextMenuDisappear: () -> Void = { [tabId = tab.id] in
            if frozenShortcutHintsTabId == tabId {
                frozenShortcutHintsTabId = nil
            }
        }

        // Per-row drag/drop snapshots. Reading `dragState` here in the parent
        // is intentional: the parent owns the @Observable store, and these
        // value snapshots are what get passed to the row. The row's
        // Equatable conformance ignores closures, so rows whose snapshot is
        // unchanged skip re-render when drag state moves.
        let isBeingDragged = dragState.draggedTabId == tab.id
        let sidebarReorderIds = renderContext.sidebarReorderIds
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: tab.id,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        let onDragStart: () -> NSItemProvider = { [tabId = tab.id] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag tab=\(tabId.uuidString.prefix(5))")
            #endif
            dragState.beginDragging(tabId: tabId)
            return SidebarTabDragPayload.provider(for: tabId)
        }
        let row = TabItemView(
            tabManager: tabManager,
            notificationStore: notificationStore,
            tab: tab,
            index: index,
            workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                at: index,
                workspaceCount: renderContext.workspaceCount
            ),
            workspaceShortcutModifierSymbol: renderContext.workspaceNumberShortcut.numberedDigitHintPrefix,
            canCloseWorkspace: renderContext.canCloseWorkspace,
            accessibilityWorkspaceCount: renderContext.workspaceCount,
            unreadCount: liveUnreadCount,
            latestNotificationText: liveLatestNotificationText,
            rowSpacing: tabRowSpacing,
            setSelectionToTabs: { selection = .tabs },
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            showsModifierShortcutHints: resolvedShowsModifierShortcutHints,
            dragAutoScrollController: dragAutoScrollController,
            isBeingDragged: isBeingDragged,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            onDragStart: onDragStart,
            contextMenuWorkspaceIds: contextMenuWorkspaceIds,
            remoteContextMenuWorkspaceIds: remoteContextMenuWorkspaceIds,
            allRemoteContextMenuTargetsConnecting: allRemoteContextMenuTargetsConnecting,
            allRemoteContextMenuTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
            contextMenuPinState: contextMenuPinState,
            workspaceGroupMenuSnapshot: renderContext.workspaceGroupMenuSnapshot,
            settings: renderContext.tabItemSettings,
            onContextMenuAppear: onContextMenuAppear,
            onContextMenuDisappear: onContextMenuDisappear
        )
        .equatable()
        .id(tab.id)
        .accessibilityIdentifier("sidebarWorkspace.\(tab.id.uuidString)")

        row
            .sidebarWorkspaceFrameAnchor(id: tab.id, isEnabled: shouldCollectWorkspaceDropTargets)
            .padding(.leading, tab.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

struct SidebarWorkspaceFrameAnchorModifier: ViewModifier {
    let id: UUID
    let isEnabled: Bool

    func body(content: Content) -> some View {
        // Branchless: always apply anchorPreference, emit [:] when disabled. An
        // if/else gives `content` distinct identity per state, so flipping
        // isEnabled at drag start/end recreated every visible row's subtree
        // (lost @State, fresh snapshot builds + relayout mid-drag). The frame
        // *reader* stays gated on the drag (#5325), so an empty emit costs nothing.
        content.anchorPreference(key: SidebarWorkspaceRowFramePreferenceKey.self, value: .bounds) { anchor in
            isEnabled ? [id: anchor] : [:]
        }
    }
}

extension View {
    func sidebarWorkspaceFrameAnchor(id: UUID, isEnabled: Bool) -> some View {
        modifier(SidebarWorkspaceFrameAnchorModifier(id: id, isEnabled: isEnabled))
    }
}

struct SidebarWorkspaceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

@MainActor
private final class SidebarDragFailsafeMonitor: ObservableObject {
    private static let escapeKeyCode: UInt16 = 53
    // One-shot timer bridges synchronous AppKit event monitors to a cancellable drag-teardown deadline.
    private var pendingClearTimer: DispatchSourceTimer?
    private var pendingClearGeneration: UInt64 = 0
    private var appResignObserver: NSObjectProtocol?
    private var keyDownMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var onRequestClear: ((String) -> Void)?

    func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if SidebarDragFailsafePolicy().shouldRequestClearWhenMonitoringStarts(
            isLeftMouseButtonDown: CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
        ) {
            requestClearSoon(reason: "mouse_up_failsafe")
        }
        if appResignObserver == nil {
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "app_resign_active")
                }
            }
        }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == Self.escapeKeyCode {
                    self?.requestClearSoon(reason: "escape_cancel")
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if SidebarDragFailsafePolicy().shouldRequestClear(forMouseEventType: event.type) {
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard SidebarDragFailsafePolicy().shouldRequestClear(forMouseEventType: event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
            }
        }
    }

    func stop() {
        pendingClearGeneration &+= 1
        pendingClearTimer?.cancel()
        pendingClearTimer = nil
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        onRequestClear = nil
    }

    private func requestClearSoon(reason: String) {
        guard pendingClearTimer == nil else { return }
#if DEBUG
        cmuxDebugLog("sidebar.dragFailsafe.schedule reason=\(reason)")
#endif
        let timer = DispatchSource.makeTimerSource(queue: .main)
        pendingClearGeneration &+= 1
        let generation = pendingClearGeneration
        timer.schedule(deadline: .now() + SidebarDragFailsafePolicy.clearDelay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pendingClearGeneration == generation else { return }
#if DEBUG
                cmuxDebugLog("sidebar.dragFailsafe.fire reason=\(reason)")
#endif
                self.pendingClearTimer = nil
                self.onRequestClear?(reason)
            }
        }
        pendingClearTimer = timer
        timer.resume()
    }
}

private struct SidebarExternalDropOverlay: View {
    let draggedTabId: UUID?

    var body: some View {
        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
            draggedTabId: draggedTabId,
            pasteboardTypes: dragPasteboardTypes
        )
        Group {
            if shouldCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .onDrop(
                        of: SidebarTabDragPayload.dropContentTypes,
                        delegate: SidebarExternalDropDelegate(draggedTabId: draggedTabId)
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SidebarExternalDropDelegate: DropDelegate {
    let draggedTabId: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        let hasSidebarPayload = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let shouldReset = SidebarOutsideDropResetPolicy().shouldResetDrag(
            draggedTabId: draggedTabId,
            hasSidebarDragPayload: hasSidebarPayload
        )
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropOutside.validate tab=\(debugShortSidebarTabId(draggedTabId)) " +
            "hasType=\(hasSidebarPayload) allowed=\(shouldReset)"
        )
#endif
        return shouldReset
    }

    func dropEntered(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.entered tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.exited tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.updated tab=\(debugShortSidebarTabId(draggedTabId)) op=move")
#endif
        // Explicit move proposal avoids AppKit showing a copy (+) cursor.
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.perform tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
        SidebarDragLifecycleNotification().postClearRequest(reason: "outside_sidebar_drop")
        return true
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

private struct SidebarFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void

    var body: some View {
#if DEBUG
        SidebarDevFooter(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
#else
        SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
#endif
    }
}

private struct SidebarFooterButtons: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void
    @State private var extensionBrowserAnchorView: NSView?
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled

    var body: some View {
        HStack(spacing: 4) {
            SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
            // The puzzle button opens the extensions browser; it only shows
            // while the experimental Extensions feature is enabled.
            if extensionsExperimentalEnabled {
                Button {
                    _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                        from: extensionBrowserAnchorView,
                        title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
                    )
                } label: {
                    CmuxSystemSymbolImage(magnified: "puzzlepiece.extension", pointSize: 12, weight: .medium)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(SidebarFooterIconButtonStyle())
                .frame(width: 22, height: 22, alignment: .center)
                .safeHelp(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityLabel(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityIdentifier("SidebarExtensionMenuButton")
                .background(TitlebarControlAnchorView { extensionBrowserAnchorView = $0 })
            }
            if let updateActionsHost = AppDelegate.shared {
                UpdatePill(model: updateViewModel, accent: cmuxAccentColor(), actions: updateActionsHost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SidebarHelpMenuAction {
    case importBrowserData
    case keyboardShortcuts
    case docs
    case changelog
    case github
    case githubIssues
    case discord
    case checkForUpdates
    case sendFeedback
    case welcome
}

private struct SidebarHelpMenuButton: View {
    private let docsURL = URL(string: "https://cmux.com/docs")
    private let changelogURL = URL(string: "https://cmux.com/docs/changelog")
    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let githubIssuesURL = URL(string: "https://github.com/manaflow-ai/cmux/issues")
    private let discordURL = URL(string: "https://discord.gg/xsgFEVrWCZ")
    private let helpTitle = String(localized: "sidebar.help.button", defaultValue: "Help")
    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private var sendFeedbackShortcutHint: String {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .sendFeedback).displayString
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "questionmark.circle", pointSize: iconSize, weight: .medium)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            helpOptionButton(
                title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!"),
                action: .welcome,
                accessibilityIdentifier: "SidebarHelpMenuOptionWelcome",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                action: .sendFeedback,
                accessibilityIdentifier: "SidebarHelpMenuOptionSendFeedback",
                isExternalLink: false,
                shortcutHint: sendFeedbackShortcutHint,
                trailingSystemImage: "bubble.left.and.text.bubble.right"
            )
            helpOptionButton(
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                action: .keyboardShortcuts,
                accessibilityIdentifier: "SidebarHelpMenuOptionKeyboardShortcuts",
                isExternalLink: false
            )
            helpOptionButton(
                title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
                action: .importBrowserData,
                accessibilityIdentifier: "SidebarHelpMenuOptionImportBrowserData",
                isExternalLink: false
            )
            if docsURL != nil {
                helpOptionButton(
                    title: String(localized: "about.docs", defaultValue: "Docs"),
                    action: .docs,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDocs",
                    isExternalLink: true
                )
            }
            if changelogURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"),
                    action: .changelog,
                    accessibilityIdentifier: "SidebarHelpMenuOptionChangelog",
                    isExternalLink: true
                )
            }
            if githubURL != nil {
                helpOptionButton(
                    title: String(localized: "about.github", defaultValue: "GitHub"),
                    action: .github,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHub",
                    isExternalLink: true
                )
            }
            if githubIssuesURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"),
                    action: .githubIssues,
                    accessibilityIdentifier: "SidebarHelpMenuOptionGitHubIssues",
                    isExternalLink: true
                )
            }
            if discordURL != nil {
                helpOptionButton(
                    title: String(localized: "sidebar.help.discord", defaultValue: "Discord"),
                    action: .discord,
                    accessibilityIdentifier: "SidebarHelpMenuOptionDiscord",
                    isExternalLink: true
                )
            }
            helpOptionButton(
                title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
                action: .checkForUpdates,
                accessibilityIdentifier: "SidebarHelpMenuOptionCheckForUpdates",
                isExternalLink: false
            )
        }
        .padding(8)
        .frame(minWidth: 200)
    }

    private func helpOptionButton(
        title: String,
        action: SidebarHelpMenuAction,
        accessibilityIdentifier: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        Button {
            isPopoverPresented = false
            perform(action)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .cmuxFont(size: 12)
                Spacer(minLength: 0)
                if let shortcutHint {
                    helpOptionShortcutHint(text: shortcutHint)
                }
                if let trailingSystemImage {
                    helpOptionTrailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    helpOptionTrailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func helpOptionShortcutHint(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .cmuxFont(size: 10, weight: .regular, design: .rounded)
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func helpOptionTrailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        CmuxSystemSymbolImage(systemName: systemName, pointSize: size)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    private func perform(_ action: SidebarHelpMenuAction) {
        switch action {
        case .importBrowserData:
            isPopoverPresented = false
            DispatchQueue.main.async {
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        case .keyboardShortcuts:
            isPopoverPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Task { @MainActor in
                    if let appDelegate = AppDelegate.shared {
                        appDelegate.openPreferencesWindow(
                            debugSource: "sidebarHelpMenu.keyboardShortcuts",
                            navigationTarget: .keyboardShortcuts
                        )
                    } else {
                        AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                    }
                }
            }
        case .docs:
            guard let docsURL else { return }
            NSWorkspace.shared.open(docsURL)
        case .changelog:
            guard let changelogURL else { return }
            NSWorkspace.shared.open(changelogURL)
        case .github:
            guard let githubURL else { return }
            NSWorkspace.shared.open(githubURL)
        case .githubIssues:
            guard let githubIssuesURL else { return }
            NSWorkspace.shared.open(githubIssuesURL)
        case .discord:
            guard let discordURL else { return }
            NSWorkspace.shared.open(discordURL)
        case .checkForUpdates:
            Task { @MainActor in
                AppDelegate.shared?.checkForUpdates(nil)
            }
        case .sendFeedback:
            isPopoverPresented = false
            onSendFeedback()
        case .welcome:
            isPopoverPresented = false
            Task { @MainActor in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openWelcomeWorkspace()
                }
            }
        }
    }

}

private struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
private struct SidebarDevFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let onSendFeedback: () -> Void
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(.red)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

private struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    let topDropIndicatorVisible: Bool
    var tabDropDelegate: SidebarTabDropDelegate? = nil
    let bonsplitDropIndicator: Binding<SidebarDropIndicator?>
    var expandsVertically = true
    var minimumHeight: CGFloat? = nil

    var body: some View {
        dropTarget
            .overlay {
                SidebarBonsplitTabNewWorkspaceDropOverlay(
                    tabManager: tabManager,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: bonsplitDropIndicator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    @ViewBuilder
    private var dropTarget: some View {
        let base = hitTarget
            .onTapGesture(count: 2) {
                // When the active workspace is a remote-tmux mirror, route through
                // performNewWorkspaceAction so a new workspace becomes a new tmux
                // session instead of a local (orphan) workspace. Gate on the
                // SELECTED tab, not `tabs.contains`: a dedicated remote window can
                // be polluted with a dragged-in local workspace (move targets don't
                // exclude dedicated windows), and `contains` would then misroute a
                // local empty-area double-tap into spawning an unwanted tmux session.
                if tabManager.selectedTab?.isRemoteTmuxMirror == true {
                    _ = AppDelegate.shared?.performNewWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "sidebar.emptyArea.remoteTmux"
                    )
                } else {
                    tabManager.addWorkspace(placementOverride: .end)
                }
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
        if let tabDropDelegate {
            base.onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
        } else {
            base
        }
    }

    @ViewBuilder
    private var hitTarget: some View {
        if expandsVertically {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: minimumHeight ?? 0)
                .contentShape(Rectangle())
        }
    }
}

private struct ExtensionSidebarBrowserStackEmptyArea: View {
    let rowSpacing: CGFloat
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let onNewTab: () -> Void
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}

// PERF: TabItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every TabManager
// or NotificationStore publish causes ALL tab items to re-evaluate (~18% of
// main thread during typing). If you add new properties, update == below.
// Reactive workspace state inside the row must not rely on parent diffs alone:
// `.equatable()` can otherwise leave sidebar badges/details stale until an
// unrelated parent change sneaks through. Keep the workspace reference plain
// and bridge only sidebar-visible workspace changes into local state.
// Do NOT add @EnvironmentObject or new @Binding without updating ==.
// Do NOT remove .equatable() from the ForEach call site in VerticalTabsSidebar.
struct SidebarWorkspaceSnapshotBuilder {
    struct PresentationKey: Equatable {
        let showsWorkspaceDescription: Bool
        let usesVerticalBranchLayout: Bool
        let showsGitBranch: Bool
        let usesViewportAwarePath: Bool
        let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
    }

    struct VerticalBranchDirectoryLine: Equatable {
        let branch: String?
        // Ordered longest → shortest. Empty means no directory to show.
        // First element is the canonical display string when only one is needed.
        let directoryCandidates: [String]

        var directory: String? { directoryCandidates.first }
    }

    struct PullRequestDisplay: Identifiable, Equatable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let ciStatus: SidebarPullRequestCIStatus
        let isStale: Bool
    }

    struct Snapshot: Equatable {
        let presentationKey: PresentationKey
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let customColorHex: String?
        let remoteWorkspaceSidebarText: String?
        let remoteConnectionStatusText: String
        let remoteStateHelpText: String
        let showsRemoteReconnectAffordance: Bool
        let copyableSidebarSSHError: String?
        let latestConversationMessage: String?
        let metadataEntries: [SidebarStatusEntry]
        let metadataBlocks: [SidebarMetadataBlock]
        let latestLog: SidebarLogEntry?
        let progress: SidebarProgressState?
        let compactGitBranchSummaryText: String?
        let compactDirectoryCandidates: [String]
        let compactBranchDirectoryCandidates: [String]
        let branchDirectoryLines: [VerticalBranchDirectoryLine]
        let branchLinesContainBranch: Bool
        let pullRequestRows: [PullRequestDisplay]
        let listeningPorts: [Int]
        let finderDirectoryPath: String?
        let mediaActivity: BrowserMediaActivity
    }
}

private final class SidebarTabItemContextMenuState: ObservableObject {
    var hasDeferredWorkspaceObservationInvalidation = false
    var pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
}

struct TabItemView: View, Equatable {
    private static let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    private static let legacyVMWebSocketDescription = "VM WebSocket PTY"

    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tab === rhs.tab &&
        lhs.index == rhs.index &&
        lhs.workspaceShortcutDigit == rhs.workspaceShortcutDigit &&
        lhs.workspaceShortcutModifierSymbol == rhs.workspaceShortcutModifierSymbol &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.latestNotificationText == rhs.latestNotificationText &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsModifierShortcutHints == rhs.showsModifierShortcutHints &&
        lhs.contextMenuWorkspaceIds == rhs.contextMenuWorkspaceIds &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.contextMenuPinState == rhs.contextMenuPinState &&
        lhs.workspaceGroupMenuSnapshot == rhs.workspaceGroupMenuSnapshot &&
        lhs.isBeingDragged == rhs.isBeingDragged &&
        lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
        lhs.bottomDropIndicatorVisible == rhs.bottomDropIndicatorVisible &&
        lhs.settings == rhs.settings
    }

    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    // Global font magnification percent, read once per row instead of through a
    // per-label `CmuxFontModifier`. Each `.cmuxFont(...)` is a custom
    // `@Environment`-reading `ViewModifier`; with 100+ workspaces continuously
    // re-rendering rows under agent churn, ~20 of those per row multiplied the
    // SwiftUI `DynamicBody`/environment node count the sidebar must re-evaluate
    // on every render pass (issue #6612, regression from #6554). Reading the
    // percent here and applying a primitive `.font(...)` keeps magnification
    // working while dropping those per-label modifier bodies.
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent
    let tab: Tab
    let index: Int
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsModifierShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Row receives precomputed drag/drop snapshot values + action closures
    // instead of an `@Observable` store reference. This keeps TabItemView in
    // compliance with the snapshot-boundary rule for views under a LazyVStack
    // (see CLAUDE.md). When drag state changes, the parent recomputes these
    // per-row snapshots and `==` skips re-render for rows whose snapshot is
    // unchanged.
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let onDragStart: () -> NSItemProvider
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let settings: SidebarTabItemSettingsSnapshot
    /// Called from this row's contextMenu.onAppear so the parent can freeze
    /// `showsModifierShortcutHints` to the value it last passed in. Prevents
    /// modifier-key transitions from flipping the badges on the row sitting
    /// behind the open context menu.
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void
    @State private var workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
    // Row-local selection projection: selectedTabId changes update only rows whose boolean flips.
    @State private var observedIsActive: Bool?
    @StateObject private var contextMenuState = SidebarTabItemContextMenuState()
    @State private var rowInteractionState = SidebarWorkspaceRowInteractionState()
    @State private var rowHeight: CGFloat = 1
    @State private var workspaceFinderDirectoryOpenRequest: WorkspaceFinderDirectoryOpenRequest?

    private static let maxWrappedTitleLines = 8
    private static let maxDisplayedTitleCharacters = 2048

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    private var sidebarShortcutHintXOffset: Double {
        settings.sidebarShortcutHintXOffset
    }

    private var sidebarShortcutHintYOffset: Double {
        settings.sidebarShortcutHintYOffset
    }

    private var alwaysShowShortcutHints: Bool {
        settings.alwaysShowShortcutHints
    }

    private var sidebarShowGitBranch: Bool {
        settings.showsGitBranch
    }

    private var sidebarBranchVerticalLayout: Bool {
        settings.usesVerticalBranchLayout
    }

    private var sidebarStacksBranchAndDirectory: Bool {
        settings.stacksBranchAndDirectory
    }

    private var sidebarUsesLastSegmentPath: Bool {
        settings.usesLastSegmentPath
    }

    private var sidebarShowGitBranchIcon: Bool {
        settings.showsGitBranchIcon
    }

    private var sidebarShowSSH: Bool {
        settings.showsSSH
    }

    private var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot {
        if let workspaceSnapshotStorage,
           workspaceSnapshotStorage.presentationKey == workspaceSnapshotPresentationKey {
            return workspaceSnapshotStorage
        }
        return makeWorkspaceSnapshot()
    }

    private var activeTabIndicatorStyle: WorkspaceIndicatorStyle {
        settings.activeTabIndicatorStyle
    }

    private var isActive: Bool {
        observedIsActive ?? (tabManager.selectedTabId == tab.id)
    }

    private var sidebarSelectionColorHex: String? {
        settings.selectionColorHex
    }

    private var sidebarNotificationBadgeColorHex: String? {
        settings.notificationBadgeColorHex
    }

    private var selectedWorkspaceBackgroundNSColor: NSColor {
        sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
    }

    private func selectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(
            on: selectedWorkspaceBackgroundNSColor,
            opacity: opacity
        )
    }

    private var openSidebarPullRequestLinksInCmuxBrowser: Bool {
        settings.openPullRequestLinksInCmuxBrowser
    }

    private var openSidebarPortLinksInCmuxBrowser: Bool {
        settings.openPortLinksInCmuxBrowser
    }

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var fontScale: CGFloat {
        settings.sidebarFontScale
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    /// Resolves a system font scaled by the global magnification percent,
    /// matching `CmuxFontModifier` exactly but without introducing a per-label
    /// custom `ViewModifier` (and its `@Environment` attribute + `DynamicBody`)
    /// for each `Text` in the row. The row reads the magnification percent once
    /// (`globalFontMagnificationPercent`) and applies a primitive `.font(...)`,
    /// removing ~20 redundant modifier bodies per row from the sidebar render
    /// pass (issue #6612).
    private func magnifiedFont(
        _ baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> Font {
        var font = Font.system(
            size: GlobalFontMagnification.scaledSize(baseSize, percent: globalFontMagnificationPercent),
            weight: weight,
            design: design
        )
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private var showsLeadingRail: Bool {
        explicitRailColor != nil
    }

    private var activeBorderLineWidth: CGFloat {
        switch activeTabIndicatorStyle {
        case .leftRail:
            return 0
        case .solidFill:
            return isActive ? 1.5 : 0
        }
    }

    private var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch activeTabIndicatorStyle {
        case .leftRail:
            return .clear
        case .solidFill:
            return Color.primary.opacity(0.5)
        }
    }

    private var usesInvertedActiveForeground: Bool {
        isActive
    }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: 1.0))
            : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    private var activeUnreadBadgeFillColor: Color {
        if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return usesInvertedActiveForeground ? activePrimaryTextColor.opacity(0.25) : cmuxAccentColor()
    }

    private var activeUnreadBadgeTextColor: Color {
        usesInvertedActiveForeground ? activePrimaryTextColor : .white
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.8) : cmuxAccentColor()
    }

    private var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }

    private var showCloseButton: Bool {
        rowInteractionState.shouldShowCloseButton(
            canCloseWorkspace: canCloseWorkspace,
            shortcutHintModeActive: showsModifierShortcutHints || alwaysShowShortcutHints
        )
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var remoteWorkspaceSidebarText: String? {
        guard tab.isRemoteWorkspace else { return nil }
        let trimmedTarget = tab.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "Remote workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.remoteConnectionState == .error || tab.remoteConnectionState == .suspended,
           let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = tab.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch tab.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .reconnecting:
            return String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        case .suspended:
            return String(localized: "remote.status.suspended", defaultValue: "Unreachable")
        }
    }

    private var rowHeightProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    rowHeight = max(proxy.size.height, 1)
                }
                .onChange(of: proxy.size.height) { _, newHeight in
                    rowHeight = max(newHeight, 1)
                }
        }
    }

    @ViewBuilder
    private var remoteWorkspaceSection: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        if !settings.hidesAllDetails, sidebarShowSSH, let remoteWorkspaceSidebarText = workspaceSnapshot.remoteWorkspaceSidebarText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(remoteWorkspaceSidebarText)
                        .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Text(workspaceSnapshot.remoteConnectionStatusText)
                        .font(magnifiedFont(scaledFontSize(9), weight: .medium))
                        .foregroundColor(activeSecondaryColor(0.58))
                        .lineLimit(1)

                    if workspaceSnapshot.showsRemoteReconnectAffordance {
                        Button {
                            tab.reconnectRemoteConnection()
                        } label: {
                            Label(
                                String(localized: "sidebar.remote.reconnect.button", defaultValue: "Reconnect"),
                                systemImage: "arrow.clockwise"
                            )
                            .labelStyle(.titleAndIcon)
                            .font(magnifiedFont(scaledFontSize(9), weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(activeSecondaryColor(0.9))
                        .safeHelp(String(
                            format: String(
                                localized: "sidebar.remote.reconnect.help",
                                defaultValue: "Reconnect to %@"
                            ),
                            locale: .current,
                            remoteWorkspaceSidebarText
                        ))
                    }
                }
            }
            .padding(.top, latestNotificationText == nil ? 1 : 2)
            .safeHelp(workspaceSnapshot.remoteStateHelpText)
        }
    }

    private func copyWorkspaceIdsToPasteboard(_ ids: [UUID], includeRefs: Bool = false) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(ids, includeRefs: includeRefs)
    }

    private func copyWorkspaceLinksToPasteboard(_ ids: [UUID]) {
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceLinks(ids)
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    private var workspaceSnapshotPresentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: sidebarBranchVerticalLayout,
            showsGitBranch: sidebarShowGitBranch,
            usesViewportAwarePath: sidebarUsesLastSegmentPath,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }

    var body: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        let closeButtonTooltip = workspaceSnapshot.isPinned
            ? protectedWorkspaceTooltip
            : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        let latestNotificationSubtitle = latestNotificationText
        let conversationMessageSubtitle = !settings.hidesAllDetails && settings.iMessageModeEnabled
            ? workspaceSnapshot.latestConversationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            : nil
        let effectiveSubtitle = latestNotificationSubtitle ?? conversationMessageSubtitle
        let detailVisibility = visibleAuxiliaryDetails
        let titleLineLimit = settings.wrapsWorkspaceTitles ? Self.maxWrappedTitleLines : 1
        let displayedTitle = workspaceSnapshot.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: Self.maxDisplayedTitleCharacters
        )
        let scaledUnreadBadgeSize = 16 * fontScale
        let scaledCloseButtonHitSize = max(16, 16 * fontScale)
        let scaledCloseButtonWidth = max(
            SidebarTrailingAccessoryWidthPolicy().closeButtonWidth,
            scaledCloseButtonHitSize
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(activeUnreadBadgeFillColor)
                        Text("\(unreadCount)")
                            .font(magnifiedFont(scaledFontSize(9), weight: .semibold))
                            .foregroundColor(activeUnreadBadgeTextColor)
                    }
                    .frame(width: scaledUnreadBadgeSize, height: scaledUnreadBadgeSize)
                }

                if workspaceSnapshot.isPinned {
                    CmuxSystemSymbolImage(magnified: "pin.fill", pointSize: scaledFontSize(9), weight: .semibold)
                        .foregroundColor(activeSecondaryColor(0.8))
                        .safeHelp(protectedWorkspaceTooltip)
                }

                // Chrome-style media-activity glyphs: a noisy or capturing
                // background browser pane is surfaced on its workspace row,
                // styled like the pin indicator. Audio is the must-have signal;
                // mic/camera follow the macOS orange/green convention.
                if workspaceSnapshot.mediaActivity.isPlayingAudio {
                    let audioPlayingTooltip = String(
                        localized: "sidebar.mediaActivity.audio.tooltip",
                        defaultValue: "Playing audio"
                    )
                    CmuxSystemSymbolImage(magnified: "speaker.wave.2.fill", pointSize: scaledFontSize(9), weight: .semibold)
                        .foregroundColor(activeSecondaryColor(0.8))
                        .safeHelp(audioPlayingTooltip)
                        .accessibilityLabel(audioPlayingTooltip)
                }

                if workspaceSnapshot.mediaActivity.isUsingMicrophone {
                    let microphoneInUseTooltip = String(
                        localized: "sidebar.mediaActivity.microphone.tooltip",
                        defaultValue: "Microphone in use"
                    )
                    CmuxSystemSymbolImage(magnified: "mic.fill", pointSize: scaledFontSize(9), weight: .semibold)
                        .foregroundColor(.orange)
                        .safeHelp(microphoneInUseTooltip)
                        .accessibilityLabel(microphoneInUseTooltip)
                }

                if workspaceSnapshot.mediaActivity.isUsingCamera {
                    let cameraInUseTooltip = String(
                        localized: "sidebar.mediaActivity.camera.tooltip",
                        defaultValue: "Camera in use"
                    )
                    CmuxSystemSymbolImage(magnified: "video.fill", pointSize: scaledFontSize(9), weight: .semibold)
                        .foregroundColor(.green)
                        .safeHelp(cameraInUseTooltip)
                        .accessibilityLabel(cameraInUseTooltip)
                }

                Text(displayedTitle)
                    .font(magnifiedFont(scaledFontSize(12.5), weight: titleFontWeight))
                    .foregroundColor(activePrimaryTextColor)
                    .lineLimit(titleLineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                // The close button is a sibling that always reserves its width
                // when the workspace is closable, so the title wraps/truncates
                // before this corner instead of flowing under the hover x. Its
                // visibility toggles via opacity so hover never re-lays-out the
                // row. (Matches the group-header plus-button pattern.)
                if canCloseWorkspace {
                    Button(action: {
                        #if DEBUG
                        cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=button")
                        #endif
                        tabManager.closeWorkspaceWithConfirmation(tab)
                    }) {
                        CmuxSystemSymbolImage(magnified: "xmark", pointSize: scaledFontSize(9), weight: .medium)
                            .foregroundColor(activeSecondaryColor(0.7))
                            .frame(width: scaledCloseButtonWidth, height: scaledCloseButtonHitSize, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .safeHelp(closeButtonTooltip)
                    .opacity(showCloseButton ? 1 : 0)
                    .allowsHitTesting(showCloseButton)
                    .accessibilityHidden(!showCloseButton)
                }
            }

            if let description = workspaceSnapshot.customDescription {
                SidebarWorkspaceDescriptionText(
                    markdown: description,
                    isActive: usesInvertedActiveForeground,
                    activeForegroundColor: activeSecondaryColor(0.84),
                    fontScale: fontScale
                )
            }

            if let subtitle = effectiveSubtitle {
                Text(subtitle)
                    .font(magnifiedFont(scaledFontSize(10)))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            remoteWorkspaceSection

            if detailVisibility.showsMetadata {
                let metadataEntries = workspaceSnapshot.metadataEntries
                let metadataBlocks = workspaceSnapshot.metadataBlocks
                if !metadataEntries.isEmpty {
                    SidebarMetadataRows(
                        entries: metadataEntries,
                        isActive: usesInvertedActiveForeground,
                        activeForegroundColor: activeSecondaryColor(0.95),
                        activeSecondaryForegroundColor: activeSecondaryColor(0.65),
                        fontScale: fontScale,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity)
                }
                if !metadataBlocks.isEmpty {
                    SidebarMetadataMarkdownBlocks(
                        blocks: metadataBlocks,
                        isActive: usesInvertedActiveForeground,
                        activeForegroundColor: activeSecondaryColor(0.8),
                        activeSecondaryForegroundColor: activeSecondaryColor(0.65),
                        fontScale: fontScale,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity)
                }
            }

            if detailVisibility.showsLog, let latestLog = workspaceSnapshot.latestLog {
                HStack(spacing: 4) {
                    CmuxSystemSymbolImage(magnified: logLevelIcon(latestLog.level), pointSize: scaledFontSize(8))
                        .foregroundColor(logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(magnifiedFont(scaledFontSize(10)))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity)
            }

            if detailVisibility.showsProgress, let progress = workspaceSnapshot.progress {
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(activeProgressTrackColor)
                            Capsule()
                                .fill(activeProgressFillColor)
                                .frame(width: max(0, geo.size.width * CGFloat(progress.value)))
                        }
                    }
                    .frame(height: max(3, 3 * fontScale))

                    if let label = progress.label {
                        Text(label)
                            .font(magnifiedFont(scaledFontSize(9)))
                            .foregroundColor(activeSecondaryColor(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity)
            }

            // Branch + directory row
            if detailVisibility.showsBranchDirectory {
                if sidebarBranchVerticalLayout {
                    if !workspaceSnapshot.branchDirectoryLines.isEmpty {
                        HStack(alignment: .top, spacing: 3) {
                            if sidebarShowGitBranchIcon, workspaceSnapshot.branchLinesContainBranch {
                                CmuxSystemSymbolImage(magnified: "arrow.triangle.branch", pointSize: scaledFontSize(9))
                                    .foregroundColor(activeSecondaryColor(0.6))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(workspaceSnapshot.branchDirectoryLines.enumerated()), id: \.offset) { _, line in
                                    if sidebarStacksBranchAndDirectory {
                                        if let branch = line.branch {
                                            Text(branch)
                                                .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                                                .foregroundColor(activeSecondaryColor(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        if !line.directoryCandidates.isEmpty {
                                            SidebarDirectoryText(
                                                candidates: line.directoryCandidates,
                                                color: activeSecondaryColor(0.75),
                                                fontScale: fontScale
                                            )
                                        }
                                    } else {
                                        HStack(spacing: 3) {
                                            if let branch = line.branch {
                                                Text(branch)
                                                    .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                                                    .foregroundColor(activeSecondaryColor(0.75))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            if line.branch != nil, !line.directoryCandidates.isEmpty {
                                                CmuxSystemSymbolImage(magnified: "circle.fill", pointSize: scaledFontSize(3))
                                                    .foregroundColor(activeSecondaryColor(0.6))
                                                    .padding(.horizontal, 1)
                                            }
                                            if !line.directoryCandidates.isEmpty {
                                                SidebarDirectoryText(
                                                    candidates: line.directoryCandidates,
                                                    color: activeSecondaryColor(0.75),
                                                    fontScale: fontScale
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if sidebarStacksBranchAndDirectory,
                          (workspaceSnapshot.compactGitBranchSummaryText != nil
                           || !workspaceSnapshot.compactDirectoryCandidates.isEmpty) {
                    HStack(alignment: .top, spacing: 3) {
                        if sidebarShowGitBranchIcon, workspaceSnapshot.compactGitBranchSummaryText != nil {
                            CmuxSystemSymbolImage(magnified: "arrow.triangle.branch", pointSize: scaledFontSize(9))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            if let branchRow = workspaceSnapshot.compactGitBranchSummaryText {
                                Text(branchRow)
                                    .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                                    .foregroundColor(activeSecondaryColor(0.75))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if !workspaceSnapshot.compactDirectoryCandidates.isEmpty {
                                SidebarDirectoryText(
                                    candidates: workspaceSnapshot.compactDirectoryCandidates,
                                    color: activeSecondaryColor(0.75),
                                    fontScale: fontScale
                                )
                            }
                        }
                    }
                } else if !workspaceSnapshot.compactBranchDirectoryCandidates.isEmpty {
                    HStack(spacing: 3) {
                        if sidebarShowGitBranchIcon, workspaceSnapshot.compactGitBranchSummaryText != nil {
                            CmuxSystemSymbolImage(magnified: "arrow.triangle.branch", pointSize: scaledFontSize(9))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        SidebarDirectoryText(
                            candidates: workspaceSnapshot.compactBranchDirectoryCandidates,
                            color: activeSecondaryColor(0.75),
                            fontScale: fontScale
                        )
                    }
                }
            }

            // Pull request rows
            if detailVisibility.showsPullRequests, !workspaceSnapshot.pullRequestRows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspaceSnapshot.pullRequestRows) { pullRequest in
                        let pullRequestNumber = String(pullRequest.number)
                        let pullRequestTitle = "\(pullRequest.label) #\(pullRequestNumber)"
                        let rowContent = HStack(spacing: 4) {
                            PullRequestStatusIcon(
                                status: pullRequest.status,
                                color: pullRequestForegroundColor,
                                fontScale: fontScale
                            )
                            Text(pullRequestTitle).underline(settings.makesPullRequestsClickable).lineLimit(1).truncationMode(.tail)
                            Text(pullRequestStatusLabel(pullRequest.status)).lineLimit(1)
                            if pullRequest.status == .open {
                                PullRequestCIStatusIcon(status: pullRequest.ciStatus, fontScale: fontScale)
                                    .safeHelp(pullRequestCIStatusHelp(pullRequest.ciStatus))
                                    .accessibilityLabel(Text(pullRequestCIStatusHelp(pullRequest.ciStatus)))
                            }
                            Spacer(minLength: 0)
                        }
                        .font(magnifiedFont(scaledFontSize(10), weight: .semibold))
                        .foregroundColor(pullRequestForegroundColor)
                        .opacity(pullRequest.isStale ? 0.5 : 1)
                        if settings.makesPullRequestsClickable {
                            Button(action: { openPullRequestLink(pullRequest.url) }) { rowContent }
                                .buttonStyle(.plain)
                                .tint(pullRequestForegroundColor)
                                .safeHelp(String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(pullRequestTitle)"))
                                .accessibilityIdentifier("SidebarPullRequestRow")
                        } else {
                            rowContent.accessibilityElement(children: .combine).accessibilityIdentifier("SidebarPullRequestRow")
                        }
                    }
                }
            }

            // Ports row
            if detailVisibility.showsPorts, !workspaceSnapshot.listeningPorts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(workspaceSnapshot.listeningPorts, id: \.self) { port in
                        let portLabel = SidebarPortDisplayText.label(for: port)
                        let portTooltip = SidebarPortDisplayText.openTooltip(for: port)
                        Button(action: {
                            openPortLink(port)
                        }) {
                            Text(portLabel)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .safeHelp(portTooltip)
                    }
                    Spacer(minLength: 0)
                }
                .font(magnifiedFont(scaledFontSize(10), design: .monospaced))
                .foregroundColor(activeSecondaryColor(0.75))
                .lineLimit(1)
            }
        }
        // No implicit .animation(value:) on agent-mutable fields: animating a
        // row-height change interpolates the LazyVStack's measured height over
        // every frame of the 0.2s curve, and with dozens of agent sessions some
        // row is always animating, so the sidebar-wide layout re-runs at display
        // refresh rate (#5764 / #5845). Lazy rows must be height-stable after
        // they appear; content changes now apply in one discrete layout pass.
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(activeBorderColor, lineWidth: activeBorderLineWidth)
                }
                .overlay(alignment: .leading) {
                    if showsLeadingRail {
                        Capsule(style: .continuous)
                            .fill(railColor)
                            .frame(width: 3)
                            .padding(.leading, 4)
                            .padding(.vertical, 5)
                            .offset(x: -1)
                    }
                }
        )
        .sidebarShortcutHintOverlay(
            text: showsWorkspaceShortcutHint ? workspaceShortcutLabel : nil,
            emphasis: shortcutHintEmphasis,
            offsetX: sidebarShortcutHintXOffset,
            offsetY: sidebarShortcutHintYOffset,
            fontSize: scaledFontSize(10)
        )
        .shortcutHintVisibilityAnimation(value: showsWorkspaceShortcutHint)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .background { rowHeightProbe }
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            SidebarWorkspaceRowHoverTracker(rowInteractionState: $rowInteractionState)
        }
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                cmuxDebugLog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=middleClick")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: index == 0,
                rowSpacing: rowSpacing
            )
        }
        .overlay(alignment: .bottom) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: bottomDropIndicatorVisible,
                isFirstRow: false,
                rowSpacing: rowSpacing,
                isBottomEdge: true
            )
        }
        .onAppear {
            updateObservedActiveState(tabManager.selectedTabId == tab.id)
            refreshWorkspaceSnapshot(force: true)
        }
        .onReceive(
            tabManager.selectedTabIdPublisher
                .map { $0 == tab.id }
                .removeDuplicates()
        ) { isSelected in
            updateObservedActiveState(isSelected)
        }
        .task(id: workspaceFinderDirectoryOpenRequest) {
            guard let request = workspaceFinderDirectoryOpenRequest else { return }
            await WorkspaceFinderDirectoryOpener.openInFinder(request.directoryURL)
            guard !Task.isCancelled, workspaceFinderDirectoryOpenRequest == request else { return }
            workspaceFinderDirectoryOpenRequest = nil
        }
        .onReceive(
            tab.sidebarImmediateObservationPublisher
                .receive(on: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            cmuxDebugLog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=immediate " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            refreshWorkspaceSnapshot()
        }
        .onReceive(
            tab.sidebarObservationPublisher
                .receive(on: RunLoop.main)
                // Prompt-time sidebar telemetry can arrive as a short burst
                // (pwd, branch, PR, shell state). Coalesce that burst so the
                // row redraws once with the settled state instead of blinking.
                .debounce(for: Self.workspaceObservationCoalesceInterval, scheduler: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            cmuxDebugLog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=debounced " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            refreshWorkspaceSnapshot()
        }
        .onChange(of: settings) { _ in
            refreshWorkspaceSnapshot(force: true)
        }
        .onDrag(onDragStart)
        .internalOnlyTabDrag()
        .onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: SidebarBonsplitTabDropDelegate(
            targetWorkspaceId: tab.id,
            tabManager: tabManager,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        ))
        .onTapGesture {
            updateSelection()
        }
        .safeHelp(workspaceSnapshot.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityAction(named: Text(moveUpActionText)) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text(moveDownActionText)) {
            moveBy(1)
        }
        .contextMenu {
            workspaceContextMenu
                .onAppear {
                    rowInteractionState.contextMenuDidAppear()
                    contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
                    contextMenuState.pendingWorkspaceSnapshot = nil
                    onContextMenuAppear()
                }
                .onDisappear {
                    rowInteractionState.contextMenuDidDisappear()
                    onContextMenuDisappear()
                    flushDeferredWorkspaceObservationInvalidation()
                }
        }
    }

    private func updateObservedActiveState(_ isActive: Bool) {
        guard observedIsActive != isActive else { return }
        observedIsActive = isActive
    }

    private func refreshWorkspaceSnapshot(force: Bool = false) {
        let nextSnapshot = makeWorkspaceSnapshot()
        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: workspaceSnapshotStorage,
            next: nextSnapshot,
            force: force,
            contextMenuVisible: rowInteractionState.contextMenuVisible
        )

        if workspaceSnapshotStorage != decision.workspaceSnapshotStorage {
            workspaceSnapshotStorage = decision.workspaceSnapshotStorage
        }
        if contextMenuState.pendingWorkspaceSnapshot != decision.pendingWorkspaceSnapshot {
            contextMenuState.pendingWorkspaceSnapshot = decision.pendingWorkspaceSnapshot
        }
        if contextMenuState.hasDeferredWorkspaceObservationInvalidation != decision.hasDeferredWorkspaceObservationInvalidation {
            contextMenuState.hasDeferredWorkspaceObservationInvalidation = decision.hasDeferredWorkspaceObservationInvalidation
        }
    }

    private func flushDeferredWorkspaceObservationInvalidation() {
        guard contextMenuState.hasDeferredWorkspaceObservationInvalidation else { return }
        contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
        if let pendingSnapshot = contextMenuState.pendingWorkspaceSnapshot {
            workspaceSnapshotStorage = pendingSnapshot
        }
        contextMenuState.pendingWorkspaceSnapshot = nil
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    @ViewBuilder
    private var workspaceContextMenu: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        let targetIds = contextMenuWorkspaceIds
        let isMulti = targetIds.count > 1
        let shouldPin = contextMenuPinState?.pinned ?? !tab.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let copyWorkspaceIDLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            isMulti: isMulti)
        let copyWorkspaceLinkLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        Button(pinLabel) {
            guard let contextMenuPinState else {
                NSSound.beep()
                return
            }
            let result = WorkspaceActionDispatcher.performPinAction(contextMenuPinState, in: tabManager)
            if result.changedWorkspaceIds.isEmpty {
                refreshWorkspaceSnapshot(force: true)
            }
            syncSelectionAfterMutation()
        }
        .disabled(contextMenuPinState == nil)

        workspaceGroupContextMenuSection(targetIds: targetIds, isMulti: isMulti)

        if let key = renameWorkspaceShortcut.keyEquivalent {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
            .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
        } else {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
        }

        if tab.hasCustomTitle {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                tabManager.clearCustomTitle(tabId: tab.id)
            }
        }

        if !isMulti {
            if let key = editWorkspaceDescriptionShortcut.keyEquivalent {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
                .keyboardShortcut(key, modifiers: editWorkspaceDescriptionShortcut.eventModifiers)
            } else {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
            }

            if tab.hasCustomDescription {
                Button(String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")) {
                    tabManager.clearCustomDescription(tabId: tab.id)
                }
            }

        }

        if !remoteContextMenuWorkspaceIds.isEmpty {
            Divider()

            Button(reconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.reconnectRemoteConnection()
                }
            }
            .disabled(allRemoteContextMenuTargetsConnecting)

            Button(disconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.disconnectRemoteConnection(clearConfiguration: false)
                }
            }
            .disabled(allRemoteContextMenuTargetsDisconnected)
        }

        Menu(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {
            let tabColorPalette = WorkspaceTabColorSettings.palette()

            if tab.customColor != nil {
                Button {
                    applyTabColor(nil, targetIds: targetIds)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }

            Button {
                promptCustomColor(targetIds: targetIds)
            } label: {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }

            if !tabColorPalette.isEmpty {
                Divider()
            }

            ForEach(tabColorPalette, id: \.id) { entry in
                Button {
                    applyTabColor(entry.hex, targetIds: targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: coloredCircleImage(color: tabColorSwatchColor(for: entry.hex)))
                    }
                }
            }
        }

        if let copyableSidebarSSHError = workspaceSnapshot.copyableSidebarSSHError {
            Button(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
                WorkspaceSurfaceIdentifierClipboardText.copy(copyableSidebarSSHError)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveBy(-1)
        }
        .disabled(index == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveBy(1)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            tabManager.moveTabsToTop(Set(targetIds))
            syncSelectionAfterMutation()
        }
        .disabled(targetIds.isEmpty)

        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveWorkspacesToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveWorkspaces(targetIds, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        if let key = closeWorkspaceShortcut.keyEquivalent {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .disabled(targetIds.isEmpty)
        }

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            closeOtherTabs(targetIds)
        }
        .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            closeTabsBelow(tabId: tab.id)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            closeTabsAbove(tabId: tab.id)
        }
        .disabled(index == 0)

        Divider()

        Button(markReadLabel) {
            markTabsRead(targetIds)
        }
        .disabled(!notificationStore.canMarkWorkspaceRead(forTabIds: targetIds))

        Button(markUnreadLabel) {
            markTabsUnread(targetIds)
        }
        .disabled(!notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds))

        Button(clearLatestNotificationLabel) {
            clearLatestNotifications(targetIds)
        }
        .disabled(!hasLatestNotifications(in: targetIds))

        Divider()

        Button(copyWorkspaceIDLabel) {
            copyWorkspaceIdsToPasteboard(targetIds)
        }
        .disabled(targetIds.isEmpty)

        Button(copyWorkspaceLinkLabel) {
            copyWorkspaceLinksToPasteboard(targetIds)
        }
        .disabled(targetIds.isEmpty)

        if !isMulti {
            Button(String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder")) {
                let url = workspaceSnapshot.finderDirectoryPath
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                workspaceFinderDirectoryOpenRequest = WorkspaceFinderDirectoryOpenRequest(directoryURL: url)
            }
            .disabled(workspaceSnapshot.finderDirectoryPath == nil)
        }
    }

    private var backgroundColor: Color {
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
        guard let color = style.color else { return .clear }
        return Color(nsColor: color).opacity(style.opacity)
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: activeTabIndicatorStyle,
            customColorHex: workspaceSnapshot.customColorHex,
            colorScheme: colorScheme
        ) else {
            return nil
        }
        return Color(nsColor: railColor).opacity(0.95)
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private var accessibilityTitle: String {
        String(localized: "accessibility.workspacePosition", defaultValue: "\(workspaceSnapshot.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)")
    }

    private func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    private func updateSelection() {
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id
        #if DEBUG
        var modStr = ""
        if modifiers.contains(.command) { modStr += "cmd " }
        if modifiers.contains(.shift) { modStr += "shift " }
        if modifiers.contains(.option) { modStr += "opt " }
        if modifiers.contains(.control) { modStr += "ctrl " }
        cmuxDebugLog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif

        let workspaceIds = tabManager.tabs.map(\.id)
        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
                existingAnchorIndex: lastSidebarSelectionIndex,
                selectedWorkspaceIds: selectedTabIds,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: workspaceIds
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            // Filter out workspaces hidden inside collapsed groups so a
            // Shift-click range never silently includes rows the user
            // can't see (e.g. clicking a collapsed group's anchor and
            // then Shift-clicking a row below would otherwise sweep
            // every collapsed child between them).
            let collapsedGroupIds: Set<UUID> = Set(
                tabManager.workspaceGroups
                    .filter { $0.isCollapsed }
                    .map(\.id)
            )
            let anchorIdsByGroup: [UUID: UUID] = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0.anchorWorkspaceId) }
            )
            let rangeIds = tabManager.tabs[lower...upper].compactMap { tab -> UUID? in
                if let gid = tab.groupId,
                   collapsedGroupIds.contains(gid),
                   anchorIdsByGroup[gid] != tab.id {
                    return nil
                }
                return tab.id
            }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }

        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: isShift,
            resolvedShiftAnchorIndex: shiftAnchorIndex,
            clickedIndex: index
        )
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forTabId: id)
        }
    }

    private func clearLatestNotifications(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.clearLatestNotification(forTabId: id)
        }
    }

    private func hasLatestNotifications(in targetIds: [UUID]) -> Bool {
        targetIds.contains { notificationStore.latestNotification(forTabId: $0) != nil }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private var remoteStateHelpText: String {
        let target = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.remoteConnectionState {
        case .connected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connected",
                    defaultValue: "Remote connected to %@"
                ),
                locale: .current,
                target
            )
        case .connecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connecting",
                    defaultValue: "Remote connecting to %@"
                ),
                locale: .current,
                target
            )
        case .reconnecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.reconnecting",
                    defaultValue: "Remote reconnecting to %@"
                ),
                locale: .current,
                target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "Remote error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return String(
                format: String(
                    localized: "sidebar.remote.help.error",
                    defaultValue: "Remote error for %@"
                ),
                locale: .current,
                target
            )
        case .disconnected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.disconnected",
                    defaultValue: "Remote disconnected from %@"
                ),
                locale: .current,
                target
            )
        case .suspended:
            return String(
                format: String(
                    localized: "sidebar.remote.help.suspended",
                    defaultValue: "SSH host %@ is unreachable. Automatic reconnect is paused — use Reconnect to retry."
                ),
                locale: .current,
                target
            )
        }
    }

    private func makeWorkspaceSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? = (detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests)
            ? tab.sidebarOrderedPanelIds()
            : nil
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  sidebarShowGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectoryCandidates: [String] = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return compactDirectoryCandidatesList(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryCandidates = compactBranchDirectoryCandidatesList(
            gitSummary: compactGitBranchSummaryText,
            directoryCandidates: compactDirectoryCandidates
        )
        let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = {
            guard detailVisibility.showsBranchDirectory,
                  sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return []
            }
            return verticalBranchDirectoryLines(orderedPanelIds: orderedPanelIds)
        }()
        let branchLinesContainBranch = sidebarShowGitBranch && branchDirectoryLines.contains { $0.branch != nil }
        let pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()

        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: workspaceSnapshotPresentationKey,
            title: tab.title,
            customDescription: settings.showsWorkspaceDescription ? sidebarVisibleCustomDescription : nil,
            isPinned: tab.isPinned,
            customColorHex: tab.customColor,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            showsRemoteReconnectAffordance: tab.remoteConnectionState == .suspended
                || tab.remoteConnectionState == .disconnected,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: tab.latestConversationMessage,
            metadataEntries: detailVisibility.showsMetadata ? tab.sidebarStatusEntriesInDisplayOrder() : [],
            metadataBlocks: detailVisibility.showsMetadata ? tab.sidebarMetadataBlocksInDisplayOrder() : [],
            latestLog: detailVisibility.showsLog ? tab.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? tab.progress : nil,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: detailVisibility.showsPorts ? tab.listeningPorts : [],
            finderDirectoryPath: WorkspaceFinderDirectoryResolver.path(for: tab),
            mediaActivity: tab.browserMediaActivity
        )
    }

    private var sidebarVisibleCustomDescription: String? {
        guard let description = tab.customDescription else { return nil }
        if tab.title.hasPrefix("vm:"),
           description.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyVMWebSocketDescription {
            return nil
        }
        return description
    }

    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }

        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }

        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }

        if orderedWorkspaceIds.count > 1 {
            for workspaceId in orderedWorkspaceIds.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: false)
            }
            if let finalWorkspaceId = orderedWorkspaceIds.last {
                _ = app.moveWorkspaceToWindow(workspaceId: finalWorkspaceId, windowId: newWindowId, focus: true)
            }
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    // latestNotificationText is now passed as a parameter from the parent view
    // to avoid subscribing to notificationStore changes in every TabItemView.

    // Builds the joined "branch · directory" candidates list for inline mode.
    // Each entry pairs the (fixed) git summary with one entry from the
    // directory candidates list, so ViewThatFits can choose how aggressively to
    // shorten the directory portion as the row width changes.
    private func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = gitBranchSummaryLines(orderedPanelIds: orderedPanelIds)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func gitBranchSummaryLines(orderedPanelIds: [UUID]) -> [String] {
        tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private func verticalBranchDirectoryLines(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        let useViewportAwarePath = sidebarUsesLastSegmentPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryCandidates: [String] = {
                guard let directory = entry.directory else { return [] }
                if useViewportAwarePath {
                    return SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? [] : [shortened]
            }()

            if branchText == nil && directoryCandidates.isEmpty {
                return nil
            }
            return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                branch: branchText,
                directoryCandidates: directoryCandidates
            )
        }
    }

    // Candidates for the inline-mode directory line, longest → shortest. When
    // viewport-aware truncation is off, returns a single element with each
    // panel directory shortened via `~/`. When on, walks per-path candidate
    // indices, bumping the rightmost path that can still shrink at each step.
    // Each emitted candidate differs from the previous by exactly one path
    // collapsing one level, so ViewThatFits sees a strictly monotone gradient
    // (`full|full`, `full|mid`, `full|leaf`, `mid|leaf`, `leaf|leaf`) — later
    // panels shrink before earlier ones, preserving the leading workspace dir
    // as long as the row width allows.
    private func compactDirectoryCandidatesList(orderedPanelIds: [UUID]) -> [String] {
        let home = SidebarPathFormatter.homeDirectoryPath
        let directories = tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        guard !directories.isEmpty else { return [] }

        if !sidebarUsesLastSegmentPath {
            let joined = directories
                .map { SidebarPathFormatter.shortenedPath($0, homeDirectoryPath: home) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }

        let perDirectoryCandidates: [[String]] = directories
            .map { SidebarPathFormatter.pathCandidates($0, homeDirectoryPath: home) }
            .filter { !$0.isEmpty }
        guard !perDirectoryCandidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: perDirectoryCandidates.count)
        var result: [String] = []
        while true {
            let pieces = zip(indices, perDirectoryCandidates).map { idx, candidates in
                candidates[idx]
            }
            let joined = pieces.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined {
                result.append(joined)
            }
            guard let bumpIdx = indices.indices.last(where: { indices[$0] < perDirectoryCandidates[$0].count - 1 }) else {
                break
            }
            indices[bumpIdx] += 1
        }
        return result
    }

    private func pullRequestDisplays(orderedPanelIds: [UUID]) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                ciStatus: pullRequest.ciStatus,
                isStale: pullRequest.isStale
            )
        }
    }

    private var pullRequestForegroundColor: Color {
        isActive ? activeSecondaryColor(0.75) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openPortLink(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        updateSelection()
        if openSidebarPortLinksInCmuxBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func pullRequestCIStatusHelp(_ status: SidebarPullRequestCIStatus) -> String {
        switch status {
        case .neutral: return String(localized: "sidebar.ciStatus.pending", defaultValue: "CI checks pending")
        case .success: return String(localized: "sidebar.ciStatus.success", defaultValue: "CI checks passed")
        case .failure: return String(localized: "sidebar.ciStatus.failed", defaultValue: "CI checks failed")
        }
    }

    private func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info:
                return activeSecondaryColor(0.5)
            case .progress:
                return activeSecondaryColor(0.8)
            case .success:
                return activeSecondaryColor(0.9)
            case .warning:
                return activeSecondaryColor(0.9)
            case .error:
                return activeSecondaryColor(0.9)
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private struct PullRequestStatusIcon: View {
        let status: SidebarPullRequestStatus
        let color: Color
        var fontScale: CGFloat = 1
        private static let closedFrameSize: CGFloat = 12
        private static let customFrameSize: CGFloat = 13

        private var closedFrameSize: CGFloat {
            Self.closedFrameSize * fontScale
        }

        private var customFrameSize: CGFloat {
            Self.customFrameSize * fontScale
        }

        var body: some View {
            switch status {
            case .open:
                PullRequestOpenIcon(color: color)
                    .scaleEffect(fontScale)
                    .frame(width: customFrameSize, height: customFrameSize)
            case .merged:
                PullRequestMergedIcon(color: color)
                    .scaleEffect(fontScale)
                    .frame(width: customFrameSize, height: customFrameSize)
            case .closed:
                CmuxSystemSymbolImage(magnified: "xmark.circle", pointSize: 7 * fontScale, weight: .regular)
                    .foregroundColor(color)
                    .frame(width: closedFrameSize, height: closedFrameSize)
            }
        }
    }

    private struct PullRequestCIStatusIcon: View {
        let status: SidebarPullRequestCIStatus
        var fontScale: CGFloat = 1
        private static let frameSize: CGFloat = 12

        private var frameSize: CGFloat {
            Self.frameSize * fontScale
        }

        private var symbolName: String {
            switch status {
            case .neutral: return "minus.circle"
            case .success: return "checkmark.circle.fill"
            case .failure: return "xmark.circle.fill"
            }
        }

        private var color: Color {
            switch status {
            case .neutral: return .secondary.opacity(0.7)
            case .success: return .green
            case .failure: return .red
            }
        }

        var body: some View {
            CmuxSystemSymbolImage(magnified: symbolName, pointSize: 8 * fontScale, weight: .semibold)
                .foregroundColor(color)
                .frame(width: frameSize, height: frameSize)
        }
    }

    private struct PullRequestOpenIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3.0, y: 4.8))
                    path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                    path.move(to: CGPoint(x: 4.8, y: 3.0))
                    path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                    path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.0, y: 9.2))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 11.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private struct PullRequestMergedIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4.6, y: 4.6))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                    path.addLine(to: CGPoint(x: 9.2, y: 7.0))

                    path.move(to: CGPoint(x: 4.6, y: 9.4))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 7.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        tabManager.applyWorkspaceColor(hex, toWorkspaceIds: targetIds)
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized, targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
    }

    private func beginWorkspaceDescriptionEditFromContextMenu() {
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }
}

private struct SidebarWorkspaceDescriptionText: View {
    let markdown: String
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    var body: some View {
        let displayMarkdown = markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: Self.maxDisplayedLines,
            maxDisplayedCharacters: Self.maxDisplayedCharacters
        )
        let renderedMarkdown = SidebarMarkdownRenderer(markdown: displayMarkdown).workspaceDescription
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
            } else {
                Text(displayMarkdown)
            }
        }
        .cmuxFont(size: 10.5 * fontScale)
        .foregroundColor(foregroundColor)
        .multilineTextAlignment(.leading)
        .lineLimit(Self.maxDisplayedLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SidebarWorkspaceDescriptionText")
        .accessibilityLabel(accessibilityText(renderedMarkdown: renderedMarkdown, displayMarkdown: displayMarkdown))
        .onAppear {
#if DEBUG
            let newlineCount = markdown.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "sidebar.description.render workspaceState=appear " +
                "len=\((markdown as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(markdown))\""
            )
#endif
        }
        .onChange(of: markdown) { newValue in
#if DEBUG
            let newlineCount = newValue.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            cmuxDebugLog(
                "sidebar.description.render workspaceState=change " +
                "len=\((newValue as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(newValue))\""
            )
#endif
        }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary.opacity(0.95)
    }

    private func accessibilityText(renderedMarkdown: AttributedString?, displayMarkdown: String) -> String {
        if let renderedMarkdown {
            return String(renderedMarkdown.characters)
        }
        return displayMarkdown
    }
}

private extension String {
    func sidebarBoundedDisplayString(maxDisplayedLines: Int, maxDisplayedCharacters: Int) -> String {
        var result = ""
        result.reserveCapacity(maxDisplayedCharacters)
        var lineCount = 1
        var characterCount = 0
        var truncated = false

        for character in self {
            if characterCount >= maxDisplayedCharacters {
                truncated = true
                break
            }
            if character == "\n" {
                if lineCount >= maxDisplayedLines {
                    truncated = true
                    break
                }
                lineCount += 1
            }
            result.append(character)
            characterCount += 1
        }

        guard truncated else { return self }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : trimmed + "..."
    }
}

private struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(
                    entry: entry,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .cmuxFont(size: 10 * fontScale, weight: .semibold)
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}

private struct SidebarMetadataEntryRow: View {
    let entry: SidebarStatusEntry
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    var body: some View {
        Group {
            if let url = entry.url {
                Button {
                    onFocus()
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = iconView {
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            metadataText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .cmuxFont(size: 10 * fontScale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return activeForegroundColor
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? activeForegroundColor.opacity(0.84) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 9 * fontScale))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).cmuxFont(size: 8 * fontScale, weight: .semibold))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(CmuxSystemSymbolImage(magnified: symbolName, pointSize: 8 * fontScale, weight: .medium))
    }

    @ViewBuilder
    private func metadataText(underlined: Bool) -> some View {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? entry.key : trimmed
        if entry.format == .markdown,
           let attributed = try? AttributedString(
                markdown: display,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        } else {
            Text(display)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }
}

private struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details") : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .cmuxFont(size: 10 * fontScale, weight: .semibold)
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleBlocks: [SidebarMetadataBlock] {
        guard !isExpanded, blocks.count > collapsedBlockLimit else { return blocks }
        return Array(blocks.prefix(collapsedBlockLimit))
    }

    private var shouldShowToggle: Bool {
        blocks.count > collapsedBlockLimit
    }
}

private struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let activeForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void
    private static let maxDisplayedLines = 12
    private static let maxDisplayedCharacters = 4096

    var body: some View {
        // Render inline (memoized) so the FIRST render is already attributed.
        // Parsing in onAppear into @State performed a guaranteed nil ->
        // attributed swap on every first appearance, changing the row's height
        // mid-scroll and re-feeding the sidebar-wide layout cycle (#5764).
        let displayMarkdown = Self.displayMarkdown(from: block.markdown)
        let renderedMarkdown = SidebarMetadataMarkdownRenderer.rendered(displayMarkdown)
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(displayMarkdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .cmuxFont(size: 10 * fontScale)
        .multilineTextAlignment(.leading)
        .lineLimit(Self.maxDisplayedLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var foregroundColor: Color {
        isActive ? activeForegroundColor : .secondary
    }

    private static func displayMarkdown(from markdown: String) -> String {
        markdown.sidebarBoundedDisplayString(
            maxDisplayedLines: maxDisplayedLines,
            maxDisplayedCharacters: maxDisplayedCharacters
        )
    }
}

/// Immutable, equatable snapshot of the group list a row's "Move to Group"
/// submenu can offer. Computed once per parent body eval and passed into
/// each TabItemView so the row's `==` covers group changes (renames, adds,
/// deletes) — the row's snapshot-boundary rule forbids reading
/// `tabManager.workspaceGroups` from inside the contextMenu builder.
enum SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = "cmux.sidebar-tab."

    static func provider(for tabId: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(prefix)\(tabId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            let data = payload.data(using: .utf8)
            Task { @MainActor in
                completion(data, nil)
            }
            return nil
        }
        return provider
    }

}

enum BonsplitTabDragPayload {
    static let typeIdentifier = "com.splittabbar.tabtransfer"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let currentProcessId = Int32(ProcessInfo.processInfo.processIdentifier)

    struct Transfer: Decodable {
        struct TabInfo: Decodable {
            let id: UUID
            let kind: String?
        }

        let tab: TabInfo
        let sourcePaneId: UUID
        let sourceProcessId: Int32

        private enum CodingKeys: String, CodingKey {
            case tab
            case sourcePaneId
            case sourceProcessId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tab = try container.decode(TabInfo.self, forKey: .tab)
            self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
            // Legacy payloads won't include this field. Treat as foreign process.
            self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
        }
    }

    private static func isCurrentProcessTransfer(_ transfer: Transfer) -> Bool {
        transfer.sourceProcessId == currentProcessId
    }

    static func currentTransfer() -> Transfer? {
        transfer(from: NSPasteboard(name: .drag))
    }

    static func canRouteWorkspaceDrop(pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            && !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboardTypes)
    }

    static func transfer(from pasteboard: NSPasteboard) -> Transfer? {
        guard !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboard.types) else {
            return nil
        }
        let type = NSPasteboard.PasteboardType(typeIdentifier)

        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        return nil
    }
}

private struct SidebarBonsplitTabDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [BonsplitTabDragPayload.typeIdentifier]) else { return false }
        return BonsplitTabDragPayload.currentTransfer() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transfer = BonsplitTabDragPayload.currentTransfer(),
              let app = AppDelegate.shared else {
            return false
        }

        if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
           source.workspaceId == targetWorkspaceId {
            syncSidebarSelection()
            return true
        }

        guard app.moveBonsplitTab(
            tabId: transfer.tab.id,
            toWorkspace: targetWorkspaceId,
            focus: true,
            focusWindow: true
        ) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelection()
        return true
    }

    private func syncSidebarSelection() {
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

@MainActor
struct SidebarTabDropDelegate: DropDelegate {
    let targetTabId: UUID?
    let tabManager: TabManager
    let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    let dragState: SidebarDragState
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController

    /// The identity of the workspace being dragged, resolved from this window's
    /// `SidebarDragState` first and falling back to the process-wide
    /// ``SidebarWorkspaceDragRegistry`` for a drag that originated in another
    /// window. This single resolver is the one source of truth the drop path
    /// keys on, so an intra-window reorder and a cross-window move share the same
    /// code instead of forking into parallel drop delegates.
    private var effectiveDraggedTabId: UUID? {
        dragState.draggedTabId ?? dragState.currentWorkspaceDragId
    }

    /// Whether `draggedTabId` belongs to a *different* window than this drop
    /// target — i.e. dropping here moves the workspace into this window rather
    /// than reordering within it.
    private func isCrossWindowDrag(_ draggedTabId: UUID) -> Bool {
        !tabManager.tabs.contains { $0.id == draggedTabId }
    }

    /// Whether the foreign dragged workspace is a group *anchor* in its source
    /// window. A group-header drag carries the anchor id, and moving only the
    /// anchor across windows would dissolve the group and strand its members,
    /// so cross-window drops of a group header are disallowed — the group stays
    /// intact and members can still be dragged out individually. (Migrating a
    /// whole group across windows is out of scope for this feature.)
    private func isCrossWindowGroupAnchorDrag(_ draggedTabId: UUID) -> Bool {
        guard isCrossWindowDrag(draggedTabId),
              let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: draggedTabId) else {
            return false
        }
        return sourceManager.workspaceGroups.contains { $0.anchorWorkspaceId == draggedTabId }
    }

    /// The destination's top-level sidebar ids (each group is represented by its
    /// anchor; members are folded into the run). A workspace moved in from
    /// another window arrives ungrouped and `attachWorkspace` normalizes it to a
    /// top-level boundary, so the planner and indicator reason in this space —
    /// not raw `tabs` — to match where the workspace actually lands.
    private func crossWindowTopLevelTabIds() -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedTabIds() -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    /// Map the hovered destination row to its top-level representative: a group
    /// member resolves to its group's anchor, since an incoming ungrouped
    /// workspace lands at the group boundary, never inside the run.
    private func crossWindowTopLevelTarget() -> UUID? {
        guard let targetTabId else { return nil }
        if let groupId = tabManager.tabs.first(where: { $0.id == targetTabId })?.groupId,
           let anchorId = tabManager.workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId {
            return anchorId
        }
        return targetTabId
    }

    /// Translate a top-level insertion slot into a raw `tabs` index so the
    /// attach lands the workspace just before that top-level item's run (or at
    /// the end); `attachWorkspace` then normalizes the group runs around it.
    private func crossWindowRawInsertIndex(forTopLevelSlot slot: Int, topLevelIds: [UUID]) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        return tabManager.tabs.firstIndex { $0.id == topLevelId } ?? tabManager.tabs.count
    }

    /// Mirror a foreign drag's identity into this window's `SidebarDragState`
    /// so the existing drop-indicator, frame-anchor, and failsafe machinery —
    /// all gated on `draggedTabId != nil` — activate unchanged. The id matches
    /// no local row, so no row dims, and the failsafe monitor clears it on
    /// mouse-up (and `performDrop` clears it on a successful drop).
    private func activateForeignDragIfNeeded() {
        guard dragState.draggedTabId == nil,
              let foreignId = dragState.currentWorkspaceDragId,
              isCrossWindowDrag(foreignId),
              !isCrossWindowGroupAnchorDrag(foreignId) else { return }
        // Resolve the foreign workspace's pin state once; it can't change while
        // the drag is in flight, so later hover updates reuse it.
        dragState.foreignDraggedIsPinned = AppDelegate.shared?
            .tabManagerFor(tabId: foreignId)?
            .tabs.first { $0.id == foreignId }?.isPinned ?? false
        dragState.draggedTabId = foreignId
    }

    func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        guard hasType, let draggedTabId = effectiveDraggedTabId else {
            #if DEBUG
            cmuxDebugLog(
                "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
                "hasType=\(hasType) hasDrag=false"
            )
            #endif
            return false
        }
        if isCrossWindowDrag(draggedTabId) {
            // A group header drag carries its anchor id; moving only the anchor
            // would dissolve the source group, so reject cross-window header
            // drops (the group stays intact in its window).
            if isCrossWindowGroupAnchorDrag(draggedTabId) {
                #if DEBUG
                cmuxDebugLog("sidebar.validateDrop crossWindow=true rejected=groupAnchor")
                #endif
                return false
            }
            // Foreign workspace: any row (or the end strip) in this window is a
            // valid drop target — the workspace will be moved into this window.
            #if DEBUG
            cmuxDebugLog(
                "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
                "hasType=true crossWindow=true"
            )
            #endif
            return true
        }
        let targetIsInReorderScope: Bool = {
            guard let targetTabId else { return true }
            let usesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
            )
            return tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                usesTopLevelRows: usesTopLevelRows
            ).contains(targetTabId)
        }()
        #if DEBUG
        cmuxDebugLog(
            "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "hasType=\(hasType) hasDrag=true inScope=\(targetIsInReorderScope)"
        )
        #endif
        return targetIsInReorderScope
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        cmuxDebugLog("sidebar.dropEntered target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropExited target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        // SwiftUI can emit row exits while a valid drag is still over the
        // sidebar, especially after indicator state invalidates row overlays.
        // Hover updates and drag-end own indicator changes.
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(pointerX: info.location.x, pointerY: plannerPointerY(for: info))
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dragState.dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        performDrop(
            pointerX: info.location.x,
            pointerY: plannerPointerY(for: info),
            shouldClearDrag: true
        )
    }

    func performDrop(pointerX: CGFloat, pointerY: CGFloat?, shouldClearDrag: Bool = true) -> Bool {
        defer {
            if shouldClearDrag {
                dragState.clearDrag()
            }
            dragAutoScrollController.stop()
        }
        #if DEBUG
        cmuxDebugLog("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        guard let draggedTabId = effectiveDraggedTabId else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        if isCrossWindowDrag(draggedTabId) {
            return performCrossWindowDrop(draggedTabId: draggedTabId)
        }
        let defaultUsesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let explicitGroupId: UUID? = nil
        let usesTopLevelRows = usesTopLevelRowsForDrop(
            draggedTabId: draggedTabId,
            explicitGroupId: explicitGroupId,
            defaultUsesTopLevelRows: defaultUsesTopLevelRows
        )
        let plannerTargetTabId = plannerTargetTabId(usesTopLevelRows: usesTopLevelRows)
        let reorderTabIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        guard let fromIndex = reorderTabIds.firstIndex(of: draggedTabId) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        guard let targetIndex = SidebarDropPlanner().targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: plannerTargetTabId,
            indicator: dragState.dropIndicator,
            tabIds: reorderTabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange
        ) else {
#if DEBUG
            cmuxDebugLog(
                "sidebar.drop.abort reason=noTargetIndex tab=\(draggedTabId.uuidString.prefix(5)) " +
                "target=\(targetTabId?.uuidString.prefix(5) ?? "end") indicator=\(debugIndicator(dragState.dropIndicator))"
            )
#endif
            return false
        }

        guard fromIndex != targetIndex || explicitGroupId != nil else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.noop from=\(fromIndex) to=\(targetIndex)")
#endif
            return true
        }

#if DEBUG
        cmuxDebugLog("sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) from=\(fromIndex) to=\(targetIndex)")
#endif
        let selectionBeforeReorder = selectedTabIds
        let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
            existingAnchorIndex: lastSidebarSelectionIndex,
            liveWorkspaceIds: tabManager.tabs.map(\.id)
        )
        let didReorder = tabManager.reorderSidebarWorkspace(
            tabId: draggedTabId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        syncSidebarSelection(
            preserving: selectionBeforeReorder,
            preferredAnchorWorkspaceId: anchorWorkspaceIdBeforeReorder
        )
        return didReorder
    }

    private func usesTopLevelRowsForDrop(
        draggedTabId: UUID?,
        explicitGroupId: UUID?,
        defaultUsesTopLevelRows: Bool
    ) -> Bool {
        guard explicitGroupId == nil else { return false }
        guard !defaultUsesTopLevelRows else { return true }
        guard let draggedTabId,
              tabManager.tabs.contains(where: { $0.id == draggedTabId }),
              let targetTabId,
              let targetGroupId = workspaceGroupIdByWorkspaceId[targetTabId] ?? nil,
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }),
              group.anchorWorkspaceId != targetTabId else {
            return false
        }
        return true
    }

    private func plannerTargetTabId(usesTopLevelRows: Bool) -> UUID? {
        guard usesTopLevelRows,
              let targetTabId,
              let targetGroupId = workspaceGroupIdByWorkspaceId[targetTabId] ?? nil,
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }),
              group.anchorWorkspaceId != targetTabId else {
            return targetTabId
        }
        return group.anchorWorkspaceId
    }

    private func plannerPointerY(for info: DropInfo) -> CGFloat? {
        return plannerPointerY(pointerY: info.location.y)
    }

    private func plannerPointerY(pointerY: CGFloat?) -> CGFloat? {
        guard targetTabId != nil else { return nil }
        return pointerY
    }

    /// Move a workspace dragged in from another window into this window at the
    /// indicated drop position. Mirrors the existing "Move Workspace to Window"
    /// action but honors the drop index and multi-selection.
    private func performCrossWindowDrop(draggedTabId: UUID) -> Bool {
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: draggedTabId),
              // A group header drag carries its anchor; moving only the anchor
              // would dissolve the group, so cross-window header drops are
              // disallowed (also gated in validateDrop).
              !sourceManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == draggedTabId }) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.crossWindow.abort reason=unresolvedRouteOrGroupAnchor tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }

        // Move the source window's whole multi-selection when the dragged
        // workspace is part of it; otherwise just the dragged workspace. Group
        // anchors in the selection are excluded for the same reason as above.
        let sourceSelection = sourceManager.sidebarSelectedWorkspaceIds
        let candidateIds: [UUID]
        if sourceSelection.contains(draggedTabId), sourceSelection.count > 1 {
            candidateIds = sourceManager.tabs.filter { sourceSelection.contains($0.id) }.map(\.id)
        } else {
            candidateIds = [draggedTabId]
        }
        let sourceAnchorIds = Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))
        let movingIds = candidateIds.filter { !sourceAnchorIds.contains($0) }
        guard !movingIds.isEmpty else { return false }

#if DEBUG
        cmuxDebugLog(
            "sidebar.drop.crossWindow.commit count=\(movingIds.count) " +
            "to=\(destinationWindowId.uuidString.prefix(5))"
        )
#endif
        // A cross-window selection can span pinned and unpinned workspaces, and
        // `attachWorkspace` normalizes each insert into the leading-pinned /
        // unpinned region individually. Plan one base slot *per pin tier* (so a
        // mixed selection doesn't scatter), then insert that tier's workspaces
        // at base + running-offset so they stay a contiguous block in source
        // order — recomputing the slot per workspace against the same indicator
        // would re-anchor to the hovered row and reverse the batch. Pin state
        // can't change mid-drag, so snapshot it once. A skipped move simply
        // doesn't advance the offset (no index gap, no stale selection).
        let pinStateById: [UUID: Bool] = Dictionary(
            uniqueKeysWithValues: movingIds.map { id in
                (id, sourceManager.tabs.first { $0.id == id }?.isPinned ?? false)
            }
        )
        var movedIds: [UUID] = []
        for isPinnedTier in [false, true] {
            let tierIds = movingIds.filter { (pinStateById[$0] ?? false) == isPinnedTier }
            guard !tierIds.isEmpty else { continue }
            // Recompute against the live destination so the tier base reflects
            // workspaces inserted by the previous tier.
            let topLevelIds = crossWindowTopLevelTabIds()
            let slot = SidebarDropPlanner().crossWindowInsertion(
                targetTabId: crossWindowTopLevelTarget(),
                draggedIsPinned: isPinnedTier,
                indicator: dragState.dropIndicator,
                tabIds: topLevelIds,
                pinnedTabIds: crossWindowTopLevelPinnedTabIds()
            ).insertionIndex
            let base = crossWindowRawInsertIndex(forTopLevelSlot: slot, topLevelIds: topLevelIds)
            var tierOffset = 0
            for workspaceId in tierIds {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspaceId,
                    windowId: destinationWindowId,
                    atIndex: base + tierOffset,
                    focus: false
                ) {
                    movedIds.append(workspaceId)
                    tierOffset += 1
                }
            }
        }

        guard !movedIds.isEmpty else { return false }
        // Focus the workspace the user actually grabbed when it moved, else the
        // last successful move. It now lives in this window, so this resolves to
        // the same-manager focus path (no second move).
        let focusId = movedIds.contains(draggedTabId) ? draggedTabId : (movedIds.last ?? draggedTabId)
        _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: destinationWindowId, focus: true)
        selectedTabIds = Set(movedIds)
        syncSidebarSelection()
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        updateDropIndicator(pointerX: info.location.x, pointerY: plannerPointerY(for: info))
    }

    func updateDropIndicator(pointerX: CGFloat, pointerY: CGFloat?) {
        if let draggedTabId = effectiveDraggedTabId, isCrossWindowDrag(draggedTabId) {
            updateCrossWindowDropIndicator(pointerY: pointerY)
            return
        }
        let defaultUsesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let explicitGroupId: UUID? = nil
        let usesTopLevelRows = usesTopLevelRowsForDrop(
            draggedTabId: dragState.draggedTabId,
            explicitGroupId: explicitGroupId,
            defaultUsesTopLevelRows: defaultUsesTopLevelRows
        )
        let plannerTargetTabId = plannerTargetTabId(usesTopLevelRows: usesTopLevelRows)
        let tabIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        let plannedIndicator = SidebarDropPlanner().indicator(
            draggedTabId: dragState.draggedTabId,
            targetTabId: plannerTargetTabId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange,
            pointerY: pointerY,
            targetHeight: targetRowHeight
        )
        let nextIndicator = plannedIndicator
        let nextUsesTopLevelRows = nextIndicator != nil && usesTopLevelRows
        guard dragState.dropIndicator != nextIndicator ||
                dragState.dropIndicatorUsesTopLevelRows != nextUsesTopLevelRows else {
            return
        }
        dragState.setDropIndicator(nextIndicator, usesTopLevelRows: usesTopLevelRows)
    }

    /// Drop indicator for a foreign workspace hovering this window. The dragged
    /// workspace is not in this window's list, so the reorder planner (which
    /// removes a source index) does not apply — use the cross-window planner.
    private func updateCrossWindowDropIndicator(pointerY: CGFloat?) {
        // Reuse the pin state stashed when the foreign drag was mirrored in,
        // avoiding a per-pointer-move cross-window lookup.
        let draggedIsPinned = dragState.foreignDraggedIsPinned ?? false
        // Plan in top-level space so the indicator lands on the same group/pin
        // boundary `attachWorkspace` will normalize the dropped workspace to.
        let nextIndicator = SidebarDropPlanner().crossWindowInsertion(
            targetTabId: crossWindowTopLevelTarget(),
            draggedIsPinned: draggedIsPinned,
            indicator: nil,
            tabIds: crossWindowTopLevelTabIds(),
            pinnedTabIds: crossWindowTopLevelPinnedTabIds(),
            pointerY: targetTabId == nil ? nil : pointerY,
            targetHeight: targetRowHeight
        ).indicator
        let usesTopLevelRows = !tabManager.workspaceGroups.isEmpty
        guard dragState.dropIndicator != nextIndicator ||
                dragState.dropIndicatorUsesTopLevelRows != usesTopLevelRows else {
            return
        }
        dragState.setDropIndicator(nextIndicator, usesTopLevelRows: usesTopLevelRows)
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private func syncSidebarSelection(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = tabManager.tabs.map(\.id)
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: tabManager.selectedTabId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}

private struct ExtensionSidebarBrowserStackDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == targetWorkspaceId {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId else {
            return false
        }
        let resolvedDropIndicator = plannedDropIndicator(for: info)
        guard let insertionPosition = insertionPosition(
            draggedWorkspaceId: draggedTabId,
            indicator: resolvedDropIndicator
        ) else {
            return false
        }
        guard let move = move(
            draggedWorkspaceId: draggedTabId,
            insertionPosition: insertionPosition,
            indicator: resolvedDropIndicator
        ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator(for info: DropInfo) {
        let nextIndicator = plannedDropIndicator(for: info)
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func plannedDropIndicator(for info: DropInfo) -> SidebarDropIndicator? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        return SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetWorkspaceId,
            tabIds: workspaceIds,
            pinnedTabIds: [],
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        ) ?? ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).sectionBoundaryIndicator(
            draggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetWorkspaceId,
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        )
    }

    private func insertionPosition(draggedWorkspaceId: UUID, indicator: SidebarDropIndicator?) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        if let indicator {
            if let indicatorWorkspaceId = indicator.tabId {
                guard let indicatorIndex = workspaceIds.firstIndex(of: indicatorWorkspaceId) else { return nil }
                return indicator.edge == .bottom ? indicatorIndex + 1 : indicatorIndex
            }
            return workspaceIds.count
        }

        guard let sourceIndex = workspaceIds.firstIndex(of: draggedWorkspaceId),
              let targetIndex = workspaceIds.firstIndex(of: targetWorkspaceId) else {
            return nil
        }
        return sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    }

    private func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
        indicator: SidebarDropIndicator?
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
            draggedWorkspaceId: draggedWorkspaceId,
            insertionPosition: insertionPosition,
            preferredTargetSectionId: preferredTargetSectionId(indicator: indicator)
        )
    }

    private func preferredTargetSectionId(indicator: SidebarDropIndicator?) -> String? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).preferredSectionId(
            targetWorkspaceId: targetWorkspaceId,
            indicator: indicator
        )
    }
}

private struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition
              ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func insertionPositionForEndMove(draggedWorkspaceId: UUID) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        guard workspaceIds.contains(draggedWorkspaceId) else { return nil }
        guard SidebarDropPlanner().indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        ) != nil else {
            return nil
        }
        return workspaceIds.count
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}
