import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
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
let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")
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
final class WeakWindowReference {
    weak var window: NSWindow?

    init(_ window: NSWindow? = nil) {
        self.window = window
    }
}

@MainActor
private final class WindowCommandPaletteOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = CommandPaletteOverlayContainerView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let chromeComposition = AppWindowChromeComposition()
    private let interactionMonitor = CommandPaletteInteractionMonitor()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var focusLockTimer: DispatchSourceTimer?
    private let scheduledFocusAction = MainActorDeferredActionScheduler()
    private var isPaletteVisible = false
    private var hasMountedPaletteRootView = false

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
        scheduledFocusAction.schedule { [weak self] in
            self?.focusIntoPalette(retries: retries)
        }
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
        scheduledFocusAction.cancel()
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
        onDismiss: @MainActor @escaping (CommandPaletteInteractionDismissal) -> Void = { _ in },
        makeRootView: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    ) {
        let wasVisible = isPaletteVisible
        if !isVisible {
            guard wasVisible || hasMountedPaletteRootView || !containerView.isHidden else { return }
            hideOverlay()
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
        isPaletteVisible = true
        hostingView.rootView = makeRootView()
        hasMountedPaletteRootView = true
        containerView.capturesMouseEvents = true
        containerView.isHidden = false
        containerView.alphaValue = 1
        if shouldPromote {
            promoteOverlayAboveSiblingsIfNeeded()
        }
        if let window {
            interactionMonitor.activate(
                for: window,
                shouldDismiss: { [weak self] event in
                    self?.shouldDismissPalette(for: event) ?? false
                },
                onWindowStateChange: { [weak self] in
                    self?.updateFocusLockForWindowState()
                },
                onDismiss: { [weak self] dismissal in
                    guard let self, self.isPaletteVisible else { return }
                    self.hideOverlay()
                    onDismiss(dismissal)
                }
            )
        }
        updateFocusLockForWindowState()
    }

    private func shouldDismissPalette(for event: CommandPalettePointerEvent) -> Bool {
        guard window != nil else { return true }
        return event.shouldDismissPalette(
            panelContainsPoint: hostingView.commandPalettePanelContains(windowPoint: event.locationInWindow)
        )
    }

    private func hideOverlay() {
        interactionMonitor.deactivate()
        stopFocusLockTimer()
        if let window, isPaletteResponder(window.firstResponder) {
            _ = window.makeFirstResponder(nil)
        }
        isPaletteVisible = false
        hostingView.rootView = AnyView(EmptyView())
        hasMountedPaletteRootView = false
        containerView.capturesMouseEvents = false
        containerView.alphaValue = 0
        containerView.isHidden = true
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

// Lifted to `CmuxFoundation.WorkspaceMountPlan` (ContentView decomposition).
// This typealias keeps call sites short.
typealias WorkspaceMountPlan = CmuxFoundation.WorkspaceMountPlan

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
            guard let tabManager,
                  let terminal = tabManager.selectedWorkspace?.focusedTerminalInputTarget()?.panel else {
                return false
            }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }
}

private func attachFileDropOverlay(
    _ overlay: FileDropOverlayView,
    to referenceView: NSView,
    in containerView: NSView
) {
    overlay.hitTestReferenceView = referenceView
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
        let activeRemoteTerminalSessionCount: Int
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
            .map { workspace -> AnyPublisher<(Snapshot, UInt64), Never> in
                guard let workspace else {
                    return Just(
                        Snapshot(
                            workspaceId: nil,
                            currentDirectory: nil,
                            remoteConfiguration: nil,
                            remoteConnectionState: nil,
                            remoteConnectionDetail: nil,
                            remoteDaemonStatus: nil,
                            activeRemoteTerminalSessionCount: 0
                        )
                    )
                    .map { ($0, UInt64(0)) }
                    .eraseToAnyPublisher()
                }
                let directoryChangeRevision = workspace.currentDirectoryChangeRevisionPublisher()
                return workspace.$currentDirectory
                    .combineLatest(
                        workspace.$remoteConfiguration,
                        workspace.$remoteConnectionState,
                        workspace.$remoteConnectionDetail
                    )
                    .combineLatest(
                        workspace.$remoteDaemonStatus,
                        workspace.$activeRemoteTerminalSessionCount
                    )
                    .map { values in
                        let (
                            previousValues,
                            remoteDaemonStatus,
                            activeRemoteTerminalSessionCount
                        ) = values
                        let (
                            currentDirectory,
                            remoteConfiguration,
                            remoteConnectionState,
                            remoteConnectionDetail
                        ) = previousValues
                        return Snapshot(
                            workspaceId: workspace.id,
                            currentDirectory: workspace.isRemoteWorkspace
                                ? workspace.presentedCurrentDirectory
                                : currentDirectory,
                            remoteConfiguration: remoteConfiguration,
                            remoteConnectionState: remoteConnectionState,
                            remoteConnectionDetail: remoteConnectionDetail,
                            remoteDaemonStatus: remoteDaemonStatus,
                            activeRemoteTerminalSessionCount: activeRemoteTerminalSessionCount
                        )
                    }
                    .combineLatest(directoryChangeRevision)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.directoryChangeGeneration &+= 1
            }
    }
}

/// Restricts unread Observation invalidation to the subtree that reads the
/// snapshot instead of making `ContentView` or `VerticalTabsSidebar` observers.
struct SidebarUnreadSnapshotReader<Content: View>: View {
    let source: SidebarUnreadModel
    let content: (SidebarUnreadSnapshot) -> Content

    init(
        source: SidebarUnreadModel,
        @ViewBuilder content: @escaping (SidebarUnreadSnapshot) -> Content
    ) {
        self.source = source
        self.content = content
    }

    var body: some View {
        content(source.snapshot)
    }
}

/// Runs an imperative unread side effect from an isolated Observation leaf.
struct SidebarUnreadSnapshotObserver: View {
    let source: SidebarUnreadModel
    let action: @MainActor (SidebarUnreadSnapshot) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: source.snapshot) { _, snapshot in
                action(snapshot)
            }
    }
}

struct ContentView: View {
    private enum CommandPaletteTaskKey: Hashable, Sendable {
        case searchIndexBuild
        case search
        case forkableAgentAvailability(String)
    }

    var updateViewModel: UpdateStateModel
    let windowId: UUID
    let featureFlags: CmuxFeatureFlags
    let sidebarUnread: SidebarUnreadModel
    let titlebarControlsLayoutModel: TitlebarControlsLayoutModel

    @MainActor
    init(
        updateViewModel: UpdateStateModel,
        windowId: UUID,
        featureFlags: CmuxFeatureFlags? = nil,
        sidebarUnread: SidebarUnreadModel? = nil,
        titlebarControlsLayoutModel: TitlebarControlsLayoutModel? = nil
    ) {
        self.updateViewModel = updateViewModel
        self.windowId = windowId
        self.featureFlags = featureFlags ?? .shared
        self.sidebarUnread = sidebarUnread ?? TerminalNotificationStore.shared.sidebarUnread
        self.titlebarControlsLayoutModel = titlebarControlsLayoutModel
            ?? TitlebarControlsLayoutModel()
    }

    @EnvironmentObject var tabManager: TabManager
    // Unread state is read imperatively by actions and passed to leaf observers.
    // ContentView itself must not observe it: one agent notification would
    // otherwise rebuild the terminal, sidebar, and window chrome together.
    var notificationStore: TerminalNotificationStore { .shared }
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @EnvironmentObject var cmuxConfigStore: CmuxConfigStore
    @EnvironmentObject var fileExplorerState: FileExplorerState
    @Environment(\.colorScheme) private var colorScheme
#if DEBUG
    @Environment(\.minimalModeInvalidationProbe) private var minimalModeInvalidationProbe
#endif
    @AppStorage(TitlebarControlsStyle.storageKey) private var titlebarControlsStyleRawValue = TitlebarControlsStyle.defaultRawValue
    @AppStorage(RightSidebarWidthSettings.maxWidthKey) private var rightSidebarMaxWidthSetting = RightSidebarWidthSettings.noOverrideValue
    @AppStorage(SessionPersistencePolicy.sidebarMinimumWidthKey) private var sidebarMinimumWidthSetting = SessionPersistencePolicy.defaultMinimumSidebarWidth
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey) private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey) private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey) private var titlebarTrafficLightTabBarInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey) private var titlebarTrafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
    @AppStorage(PaneChromeSettings.activePaneBorderColorKey) private var activePaneBorderColorHex = PaneChromeSettings.defaultColorHex
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    private var selectedLeftSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) private var leftSidebarExtensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) private var leftSidebarCustomSidebarsExperimentalEnabled
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @LiveSetting(\.notifications.paneFlashColorHex) private var paneFlashColorHex
    /// Canonical sidebar width, deliberately NOT observed by ContentView:
    /// divider ticks re-evaluate only the SidebarWidthReader wrappers that
    /// consume the width, never this body. All reads/writes outside view
    /// bodies go through `sidebarLayout.width` directly; the computed
    /// `sidebarWidth` alias keeps call sites readable.
    @State private var sidebarLayout = SidebarLayoutModel(
        width: CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
    )
    @State private var sidebarFocusBoundary = SidebarFocusBoundaryReference()
    private var sidebarWidth: CGFloat {
        get { sidebarLayout.width }
        nonmutating set { sidebarLayout.width = newValue }
    }
    @State private var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State private var isResizerDragging = false
    @State private var sidebarDragStartWidth: CGFloat?
    // Non-observed: flush pacing must not invalidate the view.
    @State private var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State private var lastReconciledPortalRenderingStatesByWorkspaceId: [UUID: Bool] = [:]
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State private var observedWindowReference = WeakWindowReference()
    private var observedWindow: NSWindow? { observedWindowReference.window }
    @State private var workspaceSwitchPortalSignalRouter = WorkspaceSwitchPortalSignalRouter()
    @State private var sidebarRenderWorkerClient: RenderWorkerClient?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @StateObject private var fileExplorerStore = FileExplorerStore()
    @StateObject private var sessionIndexStore = SessionIndexStore()
    @StateObject private var selectedWorkspaceDirectoryObserver = SelectedWorkspaceDirectoryObserver()
    @State private var commandPaletteOverlayRenderModel = CommandPaletteOverlayRenderModel()
    @State private var backgroundWorkspacePrimeCoordinator = BackgroundWorkspacePrimeCoordinator()
    @State private var workspacePresentationModeRuntimeCache = WorkspacePresentationModeRuntimeCache()
    @State private var fileExplorerWidth: CGFloat = 220
    @State private var fileExplorerDragStartWidth: CGFloat?
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State private var sidebarResizerCursorReleaseScheduler = SidebarResizerCursorReleaseScheduler()
    @State private var sidebarResizerPointerMonitor: Any?
    @State private var isResizerBandActive = false
    @State private var isSidebarResizerCursorActive = false
    @State private var sidebarResizerCursorStabilizer = MainActorRepeatingActionScheduler()
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
    @State private var commandPaletteBrowserActionTarget: BrowserActionTarget?
    @State private var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @State private var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @State private var commandPaletteSearchCommandsByID: [String: CommandPaletteCommand] = [:]
    @State private var commandPaletteNucleoSearchIndex: CommandPaletteNucleoSearchIndex<String>?
    @State private var commandPaletteTaskStore = MainActorTaskStore<CommandPaletteTaskKey>()
    @State private var commandPaletteSearchIndexBuildGeneration: UInt64 = 0
    @State private var cachedCommandPaletteResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResults: [CommandPaletteSearchResult] = []
    @State private var commandPaletteVisibleResultsVersion: UInt64 = 0
    @State private var commandPaletteVisibleResultsScope: CommandPaletteListScope?
    @State private var commandPaletteVisibleResultsFingerprint: Int?
    @State private var cachedCommandPaletteScope: CommandPaletteListScope?
    @State private var cachedCommandPaletteFingerprint: Int?
    @State private var cachedDefaultTerminalIsDefault = DefaultTerminalRegistration.currentStatus().isDefault
    @State private var commandPaletteFocusRestoreCoordinator = CommandPaletteFocusRestoreCoordinator()
    @State private var commandPalettePendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior?
    @State private var commandPaletteSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @State private var commandPaletteResolvedSearchScope: CommandPaletteListScope?
    @State private var commandPaletteResolvedSearchFingerprint: Int?
    @State private var commandPaletteResolvedMatchingQuery = ""
    @State private var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @State private var commandPaletteForkableAgentActivePanelKey: String?
    @State private var commandPaletteForkableAgentProbeIDsByPanelKey: [String: UUID] = [:]
    @State var commandPaletteForkableAgentSupportedPanelKeys: Set<String> = []
    @State var commandPaletteForkableAgentRejectedPanelKeys: Set<String> = []
    @State var commandPaletteForkableAgentSnapshotsByPanelKey: [String: SessionRestorableAgentSnapshot] = [:]
    @State var commandPaletteForkableAgentSnapshotFingerprintsByPanelKey: [String: String] = [:]
    @State var commandPaletteForkableAgentExecutableFingerprintsByPanelKey: [String: String] = [:]
    @State var commandPaletteForkableAgentRemoteContextsByPanelKey: [String: Bool] = [:]
    @State var commandPaletteForkableAgentResultHadFallbackByPanelKey: [String: Bool] = [:]
    @State var commandPaletteForkableAgentValidatedAtByPanelKey: [String: Date] = [:]
    @State private var commandPaletteForkableAgentProbeFingerprintsByPanelKey: [String: String] = [:]
    @State private var commandPaletteForkableAgentProbeResultExpiryScheduler = MainActorDeferredActionScheduler()
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
    private let sidebarResizerOcclusionResolver = SidebarResizerOcclusionResolver()
    static func tmuxWorkspacePaneExactRect(
        for panel: any Panel,
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

    private func tmuxWorkspacePaneWindowOverlayState(
        for window: NSWindow,
        unreadSnapshot explicitUnreadSnapshot: SidebarUnreadSnapshot? = nil
    ) -> TmuxWorkspacePaneOverlayRenderState? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let unreadSnapshot = explicitUnreadSnapshot ?? sidebarUnread.snapshot
        let usesWorkspacePaneOverlay = TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay
        let resolvedActivePaneBorderColorHex = WorkspaceTabColorSettings.normalizedHex(activePaneBorderColorHex)
        let shouldShowActivePaneBorder = shouldShowActivePaneBorder(for: workspace, colorHex: resolvedActivePaneBorderColorHex)
        guard usesWorkspacePaneOverlay || shouldShowActivePaneBorder else { return nil }

        let layoutSnapshot = WorkspaceContentView.effectiveTmuxLayoutSnapshot(
            cachedSnapshot: workspace.tmuxLayoutSnapshot,
            liveSnapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let contentView = window.contentView

        let unreadRects: [CGRect]
        if usesWorkspacePaneOverlay {
            let isWorkspaceManuallyUnread = unreadSnapshot.hasManualUnread(forWorkspaceId: workspace.id)
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
                        hasUnreadNotification: unreadSnapshot.hasVisibleNotificationIndicator(
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
        } else {
            unreadRects = []
        }

        let flashRect: CGRect?
        if usesWorkspacePaneOverlay {
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
        } else {
            flashRect = nil
        }

        let activePaneBorderRect: CGRect?
        if shouldShowActivePaneBorder,
           let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId] {
            let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.paneId(forPanelId: panelId)
            )
            let exactRect = contentView.flatMap { Self.tmuxWorkspacePaneExactRect(for: panel, in: $0) }
            activePaneBorderRect = Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            )
        } else {
            activePaneBorderRect = nil
        }

        if unreadRects.isEmpty, flashRect == nil, activePaneBorderRect == nil {
            guard usesWorkspacePaneOverlay else { return nil }
            return TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspace.id,
                unreadRects: [],
                flashRect: nil,
                activePaneBorderRect: nil,
                activePaneBorderColorHex: nil,
                flashToken: workspace.tmuxWorkspaceFlashToken,
                flashReason: workspace.tmuxWorkspaceFlashReason,
                workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: paneFlashColorHex)
            )
        }

        return TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspace.id,
            unreadRects: unreadRects,
            flashRect: flashRect,
            activePaneBorderRect: activePaneBorderRect,
            activePaneBorderColorHex: activePaneBorderRect == nil ? nil : resolvedActivePaneBorderColorHex,
            flashToken: workspace.tmuxWorkspaceFlashToken,
            flashReason: workspace.tmuxWorkspaceFlashReason,
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: paneFlashColorHex)
        )
    }

    private func refreshTmuxWorkspacePaneWindowOverlay(
        in window: NSWindow?,
        unreadSnapshot: SidebarUnreadSnapshot? = nil
    ) {
        guard let window else { return }
        let tmuxOverlayState = tmuxWorkspacePaneWindowOverlayState(
            for: window,
            unreadSnapshot: unreadSnapshot
        )
        WindowTmuxWorkspacePaneOverlayController.controller(
            for: window,
            createIfNeeded: tmuxOverlayState != nil
        )?.update(state: tmuxOverlayState)
    }

    private func shouldShowActivePaneBorder(for workspace: Workspace, colorHex: String?) -> Bool {
        colorHex != nil && workspace.layoutMode != .canvas && !fileExplorerState.rightSidebarOwnsInputFocus && workspace.bonsplitController.allPaneIds.count > 1
    }

    private func shouldScheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in window: NSWindow) -> Bool {
        if TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay { return true }
        if WindowTmuxWorkspacePaneOverlayController.controller(
            for: window,
            createIfNeeded: false
        )?.hasRenderedState == true { return true }
        guard let workspace = tabManager.selectedWorkspace else { return false }
        return shouldShowActivePaneBorder(for: workspace, colorHex: WorkspaceTabColorSettings.normalizedHex(activePaneBorderColorHex))
    }

    private func scheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in window: NSWindow?) {
        guard let window,
              shouldScheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in: window),
              let controller = WindowTmuxWorkspacePaneOverlayController.controller(
                  for: window,
                  createIfNeeded: true
              ) else { return }
        controller.scheduleGeometryRefresh { [weak window] in
            guard let window else { return nil }
            return tmuxWorkspacePaneWindowOverlayState(for: window)
        }
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
        sidebarResizerCursorReleaseScheduler.cancelPendingRelease()
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

    private func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: Duration = .zero) {
        sidebarResizerCursorReleaseScheduler.schedule(force: force, delay: delay) { releaseForce in
            releaseSidebarResizerCursorIfNeeded(force: releaseForce)
        }
    }

    private func updateSidebarResizerBandState(using _: NSEvent? = nil) {
        guard sidebarState.isVisible || rightSidebarVisible,
              let window = observedWindow,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live pointer location; overlapping WKWebView tracking areas can report stale cursor-update locations.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = sidebarResizerOcclusionResolver.dividerBandContains(
            point: pointInContent,
            contentBounds: contentView.bounds,
            isLeftSidebarVisible: sidebarState.isVisible,
            leftDividerX: sidebarWidth,
            isRightSidebarVisible: rightSidebarVisible,
            rightDividerX: contentView.bounds.maxX - rightSidebarWidth
        )
        let mayActivate = sidebarResizerOcclusionResolver.bandMayActivate(
            isDragging: isResizerDragging,
            isInDividerBand: isInDividerBand,
            screenPoint: NSEvent.mouseLocation,
            observedWindowNumber: window.windowNumber
        )
        isResizerBandActive = mayActivate && isInDividerBand

        if mayActivate {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // Overlapped portal/web cursorUpdate handlers run later and can temporarily reset the cursor.
            DispatchQueue.main.async {
                Self.fixedSidebarResizeCursor.set()
            }
        } else {
            hoveredResizerHandles.removeAll()
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func startSidebarResizerCursorStabilizer() {
        guard !sidebarResizerCursorStabilizer.isRunning else { return }
        sidebarResizerCursorStabilizer.startIfIdle(every: .milliseconds(16)) {
            // Ground-truth failsafe: a cancelled SwiftUI drag gesture never
            // fires onEnded, stranding isResizerDragging and pinning the
            // resize cursor. If the physical button is up, the drag is over.
            // End the registry session too — clearing only the local flag
            // left portals latched in interactive-resize mode (deferred PTY
            // resizes, immediate-path syncs) until the next real drag.
            if isResizerDragging,
               !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
                isResizerDragging = false
                sidebarDragStartWidth = nil
                fileExplorerDragStartWidth = nil
                hoveredResizerHandles.removeAll()
                releaseSidebarResizerCursorIfNeeded(force: true)
                stopSidebarResizerCursorStabilizer()
                return
            }
            updateSidebarResizerBandState()
            if isResizerBandActive || isResizerDragging {
                Self.fixedSidebarResizeCursor.set()
            } else {
                stopSidebarResizerCursorStabilizer()
            }
        }
    }

    private func stopSidebarResizerCursorStabilizer() {
        sidebarResizerCursorStabilizer.cancel()
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

    @ViewBuilder
    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        let base = sidebarResizerHandleBase(handle, width: width)
        if featureFlags.isAppKitSidebarListEnabled {
            base
                .overlay(
                    // Native divider tracking (NSSplitView's technique): a
                    // synchronous event loop that commits and presents each
                    // width change inside the mouse event.
                    SidebarDividerTracker(
                        onBegan: {
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
                                owner: tabManager,
                                in: observedWindow
                            )
                            isResizerDragging = true
                            config.captureStart()
                            activateSidebarResizerCursor()
                        },
                        onChanged: { translation in
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            config.updateWidth(translation)
                        },
                        onEnded: {
                            TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
                            isResizerDragging = false
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            config.finishDrag()
                            activateSidebarResizerCursor()
                            scheduleSidebarResizerCursorRelease()
                        }
                    )
                )
                .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
        } else {
            base
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            if !isResizerDragging {
                                TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
                                    owner: tabManager,
                                    in: observedWindow
                                )
                                isResizerDragging = true
                                config.captureStart()
                            }
                            activateSidebarResizerCursor()
                            config.updateWidth(value.translation.width)
                        }
                        .onEnded { _ in
                            if isResizerDragging {
                                TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
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
    }

    private func sidebarResizerHandleBase(
        _ handle: SidebarResizerHandle,
        width: CGFloat
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    updateSidebarResizerBandState()
                    guard isResizerBandActive || isResizerDragging else { return }
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
                        scheduleSidebarResizerCursorRelease(delay: .milliseconds(50))
                    }
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                hoveredResizerHandles.remove(handle)
                if isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
                    isResizerDragging = false
                }
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
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
        SidebarWidthReader(layout: sidebarLayout) { width in
            placedSidebarResizerOverlay(
                handle: .divider,
                edge: .leading,
                accessibilityIdentifier: "SidebarResizer",
                dividerX: { totalWidth in min(max(width, 0), totalWidth) }
            )
        }
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
        let sidebar = VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            fileExplorerState: fileExplorerState,
            featureFlags: featureFlags,
            isPresented: sidebarState.isVisible,
            sidebarUnread: sidebarUnread,
            titlebarControlsLayoutModel: titlebarControlsLayoutModel,
            windowId: windowId,
            onSendFeedback: presentFeedbackComposer,
            onToggleSidebar: { sidebarState.toggle() },
            onNewTab: {
                AppDelegate.shared?.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.hiddenNewWorkspace"
                )
            },
            observedWindowReference: observedWindowReference,
            chromeBackgroundColor: windowAppearanceSnapshot.resolvedChromeBackgroundColor,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds, lastSidebarSelectionIndex: $lastSidebarSelectionIndex, sidebarRenderWorkerClient: $sidebarRenderWorkerClient
        )
        return Group {
            if featureFlags.isAppKitSidebarListEnabled {
                // FLAG(sidebar-appkit-list-experiment): parent-driven
                // re-evaluations (divider width ticks, unrelated ContentView
                // state churn) skip the sidebar subtree; all sidebar content
                // flows through tracked dependencies that bypass the gate.
                sidebar.equatable()
            } else {
                sidebar
            }
        }
        .modifier(SidebarWidthFrameModifier(layout: sidebarLayout))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SidebarPointerEventHost(
            { sidebarFocusBoundary.attach($0) },
            onDismantle: { sidebarFocusBoundary.detach($0) }
        ))
    }

    /// Native titlebar inset reported by AppKit. Standard mode follows cmux's visual chrome;
    /// minimal WindowGroup hosts can still need the reported safe area cancelled.
    @State private var titlebarPadding: CGFloat = WindowChromeMetrics.defaultTitlebarHeight
    /// SwiftUI WindowGroup windows can still report a titlebar safe area; manually created
    /// main windows use MainWindowHostingView and report zero.
    @State private var hostingSafeAreaTop: CGFloat = 0

    private var currentIsMinimalMode: Bool {
        workspacePresentationModeRuntimeCache.isMinimalMode
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
        let selectedWorkspaceId = tabManager.selectedTabId
        // Selection reaches body before onChange reconciles the mount cache.
        // Resolve that first render from the current selection too; otherwise
        // SwiftUI rebuilds the old workspace as hidden content before mounting
        // the destination, exposing a blank transition and doing extra layout.
        let presentationMountedIds: [UUID]
        if let selectedWorkspaceId, !mountedWorkspaceIds.contains(selectedWorkspaceId) {
            presentationMountedIds = resolvedMountedWorkspaceIds(
                tabs: tabManager.tabs,
                selectedId: selectedWorkspaceId
            )
        } else {
            presentationMountedIds = mountedWorkspaceIds
        }
        let mountedWorkspaceIdSet = Set(presentationMountedIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    // Never retain a live source workspace as a loading cover:
                    // that makes mount ownership depend on a later frame signal.
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: isSelectedWorkspace,
                        isWorkspaceInputActive: isSelectedWorkspace,
                        rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus,
                        isFullScreen: isFullScreen,
                        workspacePortalPriority: isSelectedWorkspace ? 2 : 0,
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
                    .opacity(isSelectedWorkspace ? 1 : 0)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!isSelectedWorkspace)
                    .zIndex(isSelectedWorkspace ? 2 : 0)
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)
        }
        .modifier(WorkspacePresentationModeContentTopPaddingModifier(
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        ))
    }

    private func terminalContentWithSidebarDropOverlay(appearance: WindowAppearanceSnapshot) -> some View {
        terminalContent(appearance: appearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
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
        // Preserve the panel's intended edge when content reports an
        // intrinsic width larger than the constrained pane. The default
        // centered frame alignment would otherwise move the entire subtree
        // off the leading edge and clip every row by one constant offset.
        .frame(width: width, alignment: alignment)
    }

    private func sidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        SidebarWidthReader(layout: sidebarLayout) { width in
            sidebarPanelContainer(width: width, alignment: .leading, role: .leftSidebar, appearance: appearance) {
                sidebarView
            }
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
                    backgroundColor: appearance.resolvedChromeBackgroundColor
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
            onOpenSession: { entry in
                openSession(entry: entry)
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
            },
            customSidebarDataContext: { now in
                rightSidebarCustomSidebarDataContext(now: now)
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
                colorScheme: AppearanceSettings.effectiveColorScheme(for: appearanceMode, fallback: colorScheme),
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
            unreadModel: sidebarUnread,
            layoutModel: titlebarControlsLayoutModel,
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
        titlebarControlsLayoutModel.snapshot.contentSize.width
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
        return ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(
                inset: $titlebarLeadingInset,
                baseLeadingInset: { MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInset() }
            )
                .allowsHitTesting(false)

            SidebarWidthReader(layout: sidebarLayout) { width in
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
                .padding(.leading, Self.customTitlebarLeadingPadding(
                    isFullScreen: isFullScreen,
                    isSidebarVisible: sidebarState.isVisible,
                    sidebarWidth: width,
                    minimumSidebarWidth: minimumSidebarWidth,
                    titlebarLeadingInset: titlebarLeadingInset
                ))
                .padding(.trailing, 8)
            }
        }
        .frame(height: WindowChromeMetrics.appTitlebarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(TitlebarDoubleClickMonitorView())
        .overlay(alignment: .bottom) {
            SidebarWidthReader(layout: sidebarLayout) { width in
                WindowChromeBorder(
                    orientation: .horizontal,
                    backgroundColor: appearance.resolvedChromeBackgroundColor
                )
                    .padding(.leading, sidebarState.isVisible ? width : 0)
            }
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

    private func syncTrafficLightInset(isMinimalMode: Bool? = nil) {
        let resolvedIsMinimalMode = isMinimalMode ?? currentIsMinimalMode
        let inset: CGFloat = (resolvedIsMinimalMode && !sidebarState.isVisible && !isFullScreen)
            ? CGFloat(titlebarDebugChromeSnapshot.trafficLightTabBarLeadingInset)
            : 0
        tabManager.syncWorkspaceTabBarLeadingInset(inset)
    }

    private func handleWorkspacePresentationModeChange(isMinimalMode: Bool) {
        workspacePresentationModeRuntimeCache.isMinimalMode = isMinimalMode
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
        syncTrafficLightInset(isMinimalMode: isMinimalMode)
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

    /// Settle pass for a sidebar width that stopped moving: sanitize, persist,
    /// resync portal-hosted surfaces (pure SwiftUI width changes emit no
    /// portal callbacks of their own), and refresh the resizer cursor band.
    /// Runs on programmatic width changes and once per drag end — never per
    /// drag tick.
    private func settleSidebarWidth() {
        let sanitized = normalizedSidebarWidth(sidebarWidth)
        if abs(sidebarWidth - sanitized) > 0.5 {
            sidebarWidth = sanitized
            return
        }
        if abs(sidebarState.persistedWidth - sanitized) > 0.5 {
            sidebarState.persistedWidth = sanitized
        }
        schedulePortalGeometrySynchronize()
        updateSidebarResizerBandState()
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

    private func openSession(entry: SessionEntry) {
        SessionEntryResumeCoordinator.open(entry, tabManager: tabManager)
    }

    func openRightSidebarToolPane(_ mode: RightSidebarMode) {
        guard mode.canOpenAsPane, mode.isAvailable(),
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
                        reuseExisting: true,
                        duplicateWhenFocused: true
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
            reuseExisting: true,
            duplicateWhenFocused: true
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

        if tab.usesRemoteDirectoryProvenance {
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
                    rootPath: tab.trustedRemoteCurrentDirectory,
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
        if let focusedPanelId = tab.focusedPanelId,
           !tab.isRemoteTerminalSurface(focusedPanelId),
           let panelDir = tab.reportedPanelDirectory(panelId: focusedPanelId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !panelDir.isEmpty {
            return panelDir
        }
        if tab.usesRemoteDirectoryProvenance { return nil }
        return tab.presentedCurrentDirectory
    }

    private var effectiveLeftSidebarProviderId: String {
        // Keep this parent layout decision reactive to Settings while using
        // the synchronous custom-sidebar value that avoids a one-frame remount
        // mismatch when @LiveSetting initializes.
        _ = leftSidebarCustomSidebarsExperimentalEnabled
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selectedLeftSidebarProviderId,
            extensionsEnabled: leftSidebarExtensionsExperimentalEnabled,
            customSidebarsEnabled: CmuxExtensionSidebarSelection.customSidebarsEnabled
        )
    }

    private var retainsDefaultAppKitSidebarWhenHidden: Bool {
        Self.retainsDefaultAppKitSidebar(
            appKitListEnabled: featureFlags.isAppKitSidebarListEnabled,
            effectiveProviderId: effectiveLeftSidebarProviderId
        )
    }

    static func retainsDefaultAppKitSidebar(
        appKitListEnabled: Bool,
        effectiveProviderId: String
    ) -> Bool {
        appKitListEnabled
            && CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(
                effectiveProviderId: effectiveProviderId
            )
    }

    private func contentAndSidebarLayout(appearance: WindowAppearanceSnapshot) -> AnyView {
        let layout: AnyView
        // The legacy SwiftUI path uses HStack while matching so both sidebar
        // and terminal sit directly on the window background.
        let useWithinWindow = sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue
            && !sidebarMatchTerminalBackground
        if retainsDefaultAppKitSidebarWhenHidden {
            // Native sidebar identity is independent of presentation. Keep its
            // full-width subtree mounted behind a zero-width clipping shell so
            // hide/show and backdrop changes cannot cold-start the table.
            layout = AnyView(
                ZStack(alignment: .leading) {
                    terminalContentWithRightSidebarPanel(appearance: appearance)
                        .modifier(SidebarWidthLeadingPaddingModifier(
                            layout: sidebarLayout,
                            enabled: sidebarState.isVisible
                        ))
                    SidebarWidthReader(layout: sidebarLayout) { width in
                        sidebarPanelWithBackdrop(appearance: appearance)
                            .frame(width: sidebarState.isVisible ? width : 0, alignment: .leading)
                            .clipped()
                            .allowsHitTesting(sidebarState.isVisible)
                            .accessibilityHidden(!sidebarState.isVisible)
                    }
                }
            )
        } else if useWithinWindow {
            // Overlay mode keeps the left sidebar on top, but the right
            // sidebar stays in an HStack so terminal rows are clipped before
            // the sidebar backdrop samples the window.
            layout = AnyView(
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        terminalContentWithSidebarDropOverlay(appearance: appearance)
                            .modifier(SidebarWidthLeadingPaddingModifier(
                                layout: sidebarLayout,
                                enabled: sidebarState.isVisible
                            ))
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

    private func restoreMainPanelFocusAfterAppKitSidebarHiddenIfNeeded() {
        guard retainsDefaultAppKitSidebarWhenHidden,
              !isCommandPalettePresented,
              let window = observedWindow,
              let responder = window.firstResponder,
              sidebarFocusBoundary.contains(responder, in: window) else {
            return
        }

        // Resigning the retained table or field editor ends any inline edit in
        // the same way unmounting did before the sidebar became persistent.
        _ = window.makeFirstResponder(nil)

        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return
        }
        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
            workspaceId: workspace.id,
            panelId: panelId,
            in: window
        )
        workspace.focusPanel(panelId, focusIntent: panel.preferredFocusIntentForActivation())
    }

    var body: some View {
#if DEBUG
        let _ = { minimalModeInvalidationProbe.contentViewBody?() }()
#endif
        let appearance = windowAppearanceSnapshot
        var view = AnyView(
            ZStack(alignment: .topLeading) {
                WindowBackdropLayer(role: .windowRoot, snapshot: appearance)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                contentAndSidebarLayout(appearance: appearance)

                WorkspaceTitlebarModeLayer {
                    workspaceTitlebarBand(appearance: appearance)
                        .zIndex(100)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)
                .background(
                    MinimalModeTitlebarEventSurfaceLayer(isFullScreen: isFullScreen)
                )
                .background(
                    WorkspacePresentationModeChangeObserver { isMinimalMode in
                        handleWorkspacePresentationModeChange(isMinimalMode: isMinimalMode)
                    }
                )
        )

        view = AnyView(view.onAppear {
            sidebarState.installVisibilityWillChangeHandler(ownerId: windowId) { isVisible in
                if !isVisible {
                    restoreMainPanelFocusAfterAppKitSidebarHiddenIfNeeded()
                }
            }
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
                guard !tabManager.isFinalizedForWindowClose else { return }
                var didRecover = false

                // Ensure there is at least one workspace.
                if tabManager.recoverEmptyWorkspaceAfterStartupIfNeeded() {
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
            // SwiftUI may deliver an earlier selection after the model has
            // already advanced again. Reconcile the current model value once,
            // regardless of which intermediate value triggered this callback.
            let authoritativeSelection = tabManager.selectedTabId
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) " +
                    "delivered=\(debugShortWorkspaceId(newValue)) selected=\(debugShortWorkspaceId(authoritativeSelection))"
                )
            } else {
                cmuxDebugLog(
                    "ws.view.selectedChange id=none delivered=\(debugShortWorkspaceId(newValue)) " +
                    "selected=\(debugShortWorkspaceId(authoritativeSelection))"
                )
            }
#endif
            tabManager.applyWindowBackgroundForSelectedTab()
            let retiringWorkspaceID = startWorkspaceHandoffIfNeeded(
                newSelectedId: authoritativeSelection
            )
            // Begin the retirement interval before reconciliation writes the
            // source portal's hidden state. The gate defers the actual unfocus
            // until TabManager's queued focus pass has installed its target.
            if let retiringWorkspaceID {
                completeWorkspaceHandoff(
                    retiringWorkspaceID: retiringWorkspaceID,
                    reason: "mount_reconciled"
                )
            }
            reconcileMountedWorkspaceIds(selectedId: authoritativeSelection)
            AppDelegate.shared?.syncBonsplitTabShortcutHintEligibility(in: observedWindow)
            guard let authoritativeSelection else { return }
            if selectedTabIds.count <= 1 {
                selectedTabIds = [authoritativeSelection]
                lastSidebarSelectionIndex = tabManager.tabs.firstIndex {
                    $0.id == authoritativeSelection
                }
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
            guard tabManager.shouldRefreshTitleChrome(for: notification) else { return }
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
        }.onReceive(NotificationCenter.default.publisher(for: .systemAppearanceDidChange)) { _ in scheduleTitlebarThemeRefresh(reason: "systemAppearanceChanged") })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .sharedLiveAgentIndexDidChange)) { notification in
            refreshCommandPaletteForkableAgentAvailabilityAfterSharedIndexChange(notification)
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
            if selectedWorkspaceInputIsReady(workspaceID: tabId) {
                tabManager.workspaceSwitchCoordinator.noteInteractionReady(
                    workspaceID: tabId
                )
                clearWorkspaceSwitchPortalSignalsIfFinished()
            }
            let focusTransactionId = notification.userInfo?[GhosttyNotificationKey.focusTransactionId] as? UUID
            refreshTmuxWorkspacePaneWindowOverlay(in: observedWindow)
            attemptCommandPaletteFocusRestoreIfNeeded(focusTransactionId: focusTransactionId)
            scheduleTitlebarTextRefresh()
        })

        view = AnyView(view.background {
            // Update the AppKit-owned pane overlay from a dedicated Observation
            // leaf, without making ContentView itself an unread observer.
            SidebarUnreadSnapshotObserver(source: sidebarUnread) { snapshot in
                refreshTmuxWorkspacePaneWindowOverlay(
                    in: observedWindow,
                    unreadSnapshot: snapshot
                )
            }
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspacePaneGeometryDidChange)) { notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  tabId == tabManager.selectedTabId else { return }
            scheduleTmuxWorkspacePaneWindowOverlayGeometryRefresh(in: observedWindow)
            noteSelectedTerminalPortalPresentedIfReady()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .workspaceLayoutModeDidChange)) { notification in
            guard (notification.object as? Workspace)?.id == tabManager.selectedTabId else { return }
            refreshTmuxWorkspacePaneWindowOverlay(in: observedWindow)
        })

        view = AnyView(view.onChange(of: activePaneBorderColorHex) { _, _ in
            refreshTmuxWorkspacePaneWindowOverlay(in: observedWindow)
        })

        view = AnyView(view.onChange(of: paneFlashColorHex) { _, newValue in
            guard let window = observedWindow else { return }
            WindowTmuxWorkspacePaneOverlayController.controller(
                for: window,
                createIfNeeded: false
            )?.updateWorkspaceAttentionColor(
                WorkspaceAttentionColor(configuredHex: newValue)
            )
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
            tabManager.workspaceSwitchCoordinator.noteInteractionReady(
                workspaceID: tabId
            )
            clearWorkspaceSwitchPortalSignalsIfFinished()
            let focusTransactionId = notification.userInfo?[GhosttyNotificationKey.focusTransactionId] as? UUID
                ?? tabManager.selectedWorkspace?.activeFocusTransactionId
            attemptCommandPaletteFocusRestoreIfNeeded(focusTransactionId: focusTransactionId)
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedPanelId = selectedWorkspace.focusedPanelId,
                  let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                  focusedBrowser.webView === webView else { return }
            tabManager.workspaceSwitchCoordinator.noteBrowserInteractionReady(
                workspaceID: selectedTabId,
                webView: webView
            )
            clearWorkspaceSwitchPortalSignalsIfFinished()
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: focusedPanelId,
                in: observedWindow ?? webView.window
            )
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick)) { notification in
            guard let webView = notification.object as? WKWebView,
                  let selectedTabId = tabManager.selectedTabId,
                  let selectedWorkspace = tabManager.selectedWorkspace,
                  let focusedBrowser = selectedWorkspace.panels.values.compactMap({ $0 as? BrowserPanel })
                    .first(where: { $0.webView === webView }) else { return }
            tabManager.workspaceSwitchCoordinator.noteBrowserInteractionReady(
                workspaceID: selectedTabId,
                webView: webView
            )
            clearWorkspaceSwitchPortalSignalsIfFinished()
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
            tabManager.workspaceSwitchCoordinator.noteBrowserInteractionReady(
                workspaceID: selectedTabId,
                webView: focusedBrowser.webView
            )
            clearWorkspaceSwitchPortalSignalsIfFinished()
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: selectedTabId,
                panelId: panelId,
                in: observedWindow ?? focusedBrowser.webView.window
            )
            attemptCommandPaletteFocusRestoreIfNeeded()
        })

        view = AnyView(view.onReceive(workspaceSwitchPortalSignalRouter.publisher(
            for: .terminalPortalVisibilityDidChange
        )) { notification in
            guard let hostedView = notification.object as? GhosttySurfaceScrollView else { return }
            noteTerminalPortalPresentedIfReady(hostedView)
        })

        view = AnyView(view.onReceive(workspaceSwitchPortalSignalRouter.publisher(
            for: .terminalSurfaceHostedViewDidMoveToWindow
        )) { notification in
            guard let surface = notification.object as? TerminalSurface else { return }
            noteTerminalPortalPresentedIfReady(surface.hostedView)
        })

        view = AnyView(view.onReceive(workspaceSwitchPortalSignalRouter.publisher(
            for: .terminalPortalDidBecomePresentable
        )) { notification in
            guard let hostedView = notification.object as? GhosttySurfaceScrollView else { return }
            noteTerminalPortalPresentedIfReady(hostedView)
        })

        view = AnyView(view.onReceive(workspaceSwitchPortalSignalRouter.publisher(
            for: .browserPortalRegistryDidChange
        )) { notification in
            guard tabManager.workspaceSwitchCoordinator.isMeasuringSwitch,
                  let webView = notification.object as? WKWebView,
                  webView.window === (observedWindow ?? tabManager.window),
                  BrowserWindowPortalRegistry.isPresented(webView) else {
                return
            }
            tabManager.workspaceSwitchCoordinator.noteBrowserPortalPresented(webView: webView)
            clearWorkspaceSwitchPortalSignalsIfFinished()
        })

        view = AnyView(view.onReceive(workspaceSwitchPortalSignalRouter.publisher(
            for: .browserPortalDidBecomePresentable
        )) { notification in
            guard tabManager.workspaceSwitchCoordinator.isMeasuringSwitch,
                  let webView = notification.object as? WKWebView,
                  BrowserWindowPortalRegistry.isPresented(webView) else {
                return
            }
            tabManager.workspaceSwitchCoordinator.noteBrowserPortalPresented(webView: webView)
            clearWorkspaceSwitchPortalSignalsIfFinished()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: .workspaceSwitchDidFinish,
            object: tabManager.workspaceSwitchCoordinator
        )) { _ in
            guard !tabManager.workspaceSwitchCoordinator.isMeasuringSwitch else { return }
            workspaceSwitchPortalSignalRouter.clearSources()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )) { _ in
            attemptCommandPaletteFocusRestoreIfNeeded()
            attemptCommandPaletteTextSelectionIfNeeded()
        })

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification,
            object: observedWindow
        )) { notification in
            guard let observedWindow,
                  (notification.object as? NSWindow) === observedWindow else {
                return
            }
            if let manager = AppDelegate.shared?.tabManagerFor(windowId: windowId) {
                guard let selectedWorkspaceID = manager.selectedTabId else { return }
                manager.workspaceSwitchCoordinator.noteInteractionNoLongerRequired(
                    workspaceID: selectedWorkspaceID
                )
            }
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

        view = AnyView(view.onReceive(NotificationCenter.default.publisher(for: .savedLayoutSaveRequested)) { notification in
            if Self.shouldHandleSavedLayoutSaveRequest(observedWindow: observedWindow, requestedWindow: notification.object as? NSWindow, keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow) {
                presentSavedLayoutSavePrompt()
            }
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
            refreshTmuxWorkspacePaneWindowOverlay(in: window)
            let overlayController = commandPaletteWindowOverlayController(for: window)
            overlayController.update(
                isVisible: isCommandPalettePresented,
                onDismiss: { dismissal in
                    dismissCommandPalette(for: dismissal, in: window)
                }
            ) { AnyView(commandPaletteOverlay) }
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
                isMinimalMode: currentIsMinimalMode
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
                isMinimalMode: currentIsMinimalMode
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

        // onReceive, not onChange: ContentView deliberately does not track
        // sidebar width in its body anymore (see sidebarLayout), so onChange
        // would never fire. Delivery hops to the main queue (Combine otherwise
        // runs this synchronously INSIDE each width write — measured as a
        // 7.6ms/event write-phase regression during drags; DispatchQueue.main
        // rather than RunLoop.main so delivery survives modal panels and
        // menu tracking, same rule as the sidebar observation pipeline), and
        // the settle work skips mid-drag entirely: the tracking loop plus
        // portal anchor callbacks own live geometry, and the drag-end handler
        // below runs the full settle once.
        view = AnyView(view.onReceive(
            sidebarLayout.$width.removeDuplicates().receive(on: DispatchQueue.main)
        ) { _ in
            guard !isResizerDragging else { return }
            settleSidebarWidth()
        })
        view = AnyView(view.onReceive(
            NotificationCenter.default.publisher(for: .cmuxInteractiveGeometryResizeDidEnd)
        ) { _ in
            settleSidebarWidth()
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
            sidebarState.removeVisibilityWillChangeHandler(ownerId: windowId)
            workspaceSwitchPortalSignalRouter.clearSources()
            if isResizerDragging {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: tabManager)
                isResizerDragging = false
                sidebarDragStartWidth = nil
            }
            cancelCommandPaletteForkableAgentProbeResultExpiryRefresh()
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

        return AnyView(
            view
                .environment(
                    \.workspaceAttentionColor,
                    WorkspaceAttentionColor(configuredHex: paneFlashColorHex)
                )
                .cmuxAppearanceColorScheme(appearanceMode)
        )
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
        workspaceSwitchPortalSignalRouter.attach(to: window)
        if observedWindow !== window {
            DispatchQueue.main.async {
                observedWindowReference = WeakWindowReference(window)
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
            refreshTmuxWorkspacePaneWindowOverlay(in: window)
            commandPaletteWindowOverlayController(for: window)
                .update(
                    isVisible: isCommandPalettePresented,
                    onDismiss: { dismissal in
                        dismissCommandPalette(for: dismissal, in: window)
                    }
                ) { commandPaletteOverlayView }
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

    private func resolvedMountedWorkspaceIds(tabs: [Workspace], selectedId: UUID?) -> [UUID] {
        let pinnedIds = tabManager.mountedBackgroundWorkspaceLoadIds
            .union(tabManager.debugPinnedWorkspaceLoadIds)
        let selectedCount = selectedId == nil ? 0 : 1
        return WorkspaceMountPlan(
            current: mountedWorkspaceIds,
            selected: selectedId,
            pinnedIds: pinnedIds,
            orderedTabIds: tabs.map { $0.id },
            maxMounted: max(WorkspaceMountPlan.maxMountedWorkspaces, selectedCount + pinnedIds.count)
        ).mountedWorkspaceIds
    }

    private func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
        let currentTabs = tabs ?? tabManager.tabs
        let orderedTabIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? tabManager.selectedTabId
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = resolvedMountedWorkspaceIds(tabs: currentTabs, selectedId: effectiveSelectedId)
        let removedIds = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
        let portalRenderingChanges = WorkspacePortalRenderingPlan(
            previousStatesByWorkspaceId: lastReconciledPortalRenderingStatesByWorkspaceId,
            mountedWorkspaceIds: Set(mountedWorkspaceIds), orderedWorkspaceIds: orderedTabIds
        ).applying(to: &lastReconciledPortalRenderingStatesByWorkspaceId)
        let workspacesById = Dictionary(currentTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for change in portalRenderingChanges {
            workspacesById[change.workspaceId]?.setPortalRenderingEnabled(change.isEnabled, reason: "workspaceMount")
        }
        tabManager.workspaceSwitchCoordinator.selectionDidReconcile(
            workspaceID: effectiveSelectedId.flatMap { mountedWorkspaceIds.contains($0) ? $0 : nil }
        )
#if DEBUG
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(debugMsText(dtMs)) " +
                    "selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removedIds))"
                )
            } else {
                cmuxDebugLog(
                    "ws.mount.reconcile id=none selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        }
#endif
    }

    private func addTab() {
        tabManager.addWorkspaceIfActive()
        sidebarSelectionState.selection = .tabs
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        windowChrome.backdropController.updateGlassTint(to: window, color: tintColor)
    }

    private func startWorkspaceHandoffIfNeeded(
        newSelectedId: UUID?
    ) -> UUID? {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            if let newSelectedId,
               oldSelectedId == newSelectedId,
               tabManager.workspaceSwitchCoordinator.isMeasuringSwitch {
                return nil
            }
            tabManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            tabManager.cancelPendingWorkspaceHandoffRetirement()
            tabManager.workspaceSwitchCoordinator.cancel()
            workspaceSwitchPortalSignalRouter.clearSources()
            return nil
        }

        let presentationTarget = workspaceSwitchPresentationTarget(
            for: newSelectedId,
            sourceWorkspaceID: oldSelectedId
        )
        configureWorkspaceSwitchPortalSignals(for: newSelectedId)
        tabManager.workspaceSwitchCoordinator.beginPresentation(
            presentationTarget,
            retiringWorkspaceID: oldSelectedId
        )

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
        return oldSelectedId
    }

    private func completeWorkspaceHandoff(
        retiringWorkspaceID: UUID,
        reason: String
    ) {
        tabManager.workspaceSwitchCoordinator.sourceWillRetire(
            workspaceID: retiringWorkspaceID,
            targetWorkspaceID: tabManager.selectedTabId
        )

        // Unmount teardown does not hide portals during transient rebuilds or
        // cancel stale layout follow-ups, so make the old portal state explicit.
        if let workspace = tabManager.tabs.first(where: {
            $0.id == retiringWorkspaceID
        }) {
            workspace.setPortalRenderingEnabled(false, reason: "workspaceHandoff")
            lastReconciledPortalRenderingStatesByWorkspaceId[workspace.id] = false
        }

        // TabManager's focus pass is deferred. Record the retirement now so
        // it is completed after that pass creates the source panel's unfocus
        // target, including coalesced selection changes.
        tabManager.requestWorkspaceHandoffRetirement(
            workspaceID: retiringWorkspaceID,
            reason: reason
        )
#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(debugMsText(dtMs)) reason=\(reason) retiring=\(debugShortWorkspaceId(retiringWorkspaceID))"
            )
        } else {
            cmuxDebugLog("ws.handoff.complete id=none reason=\(reason) retiring=\(debugShortWorkspaceId(retiringWorkspaceID))")
        }
#endif
    }

    private func configureWorkspaceSwitchPortalSignals(for workspaceID: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            workspaceSwitchPortalSignalRouter.clearSources()
            return
        }
        if let focusedPanelID = workspace.focusedPanelId,
           let browserPanel = workspace.browserPanel(for: focusedPanelID) {
            workspaceSwitchPortalSignalRouter.observe(
                terminalHostedView: nil,
                terminalSurface: nil,
                browserWebView: browserPanel.webView
            )
            return
        }
        if let terminalTarget = workspace.focusedTerminalInputTarget() {
            workspaceSwitchPortalSignalRouter.observe(
                terminalHostedView: terminalTarget.panel.hostedView,
                terminalSurface: terminalTarget.panel.surface,
                browserWebView: nil
            )
            return
        }
        workspaceSwitchPortalSignalRouter.clearSources()
    }

    private func workspaceSwitchPresentationTarget(
        for workspaceID: UUID,
        sourceWorkspaceID: UUID
    ) -> WorkspaceSwitchPresentationTarget {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return passiveWorkspaceSwitchPresentationTarget(workspaceID: workspaceID)
        }

        let window = observedWindow ?? tabManager.window
        let requiresInteraction = workspaceSwitchRequiresInteraction(
            in: window,
            sourceWorkspaceID: sourceWorkspaceID
        )
        if let focusedPanelID = workspace.focusedPanelId,
           let browserPanel = workspace.browserPanel(for: focusedPanelID) {
            let webView = browserPanel.webView
            let portalPresented = BrowserWindowPortalRegistry.isPresented(webView)
            let interactionReady =
                window.flatMap { window in
                    window.firstResponder.flatMap {
                        browserPanel.ownedFocusIntent(for: $0, in: window)
                    }
                } != nil
            return WorkspaceSwitchPresentationTarget(
                workspaceID: workspaceID,
                contentKind: .browser,
                terminalSurfaceID: nil,
                terminalView: nil,
                terminalRendererPresented: false,
                terminalRenderedFrameSequence: 0,
                browserWebView: webView,
                portalPresented: portalPresented,
                interactionReady: interactionReady,
                requiresInteraction: requiresInteraction
            )
        }

        if let target = workspace.focusedTerminalInputTarget() {
            let surface = target.panel.surface
            let hostedView = target.panel.hostedView
            let portalPresented = TerminalWindowPortalRegistry.isPresented(hostedView)
            let interactionReady = terminalInteractionIsReady(
                target.panel,
                in: window
            )
            return WorkspaceSwitchPresentationTarget(
                workspaceID: workspaceID,
                contentKind: .terminal,
                terminalSurfaceID: target.surfaceID,
                terminalView: hostedView.surfaceView,
                terminalRendererPresented: surface.isRendererPresented,
                terminalRenderedFrameSequence:
                    hostedView.surfaceView.renderedFrameSequence,
                browserWebView: nil,
                portalPresented: portalPresented,
                interactionReady: interactionReady,
                requiresInteraction:
                    requiresInteraction &&
                    AppDelegate.shared?.allowsTerminalKeyboardFocus(
                        workspaceId: workspaceID,
                        panelId: target.surfaceID,
                        in: window
                    ) != false
            )
        }

        return passiveWorkspaceSwitchPresentationTarget(workspaceID: workspaceID)
    }

    private func passiveWorkspaceSwitchPresentationTarget(
        workspaceID: UUID
    ) -> WorkspaceSwitchPresentationTarget {
        WorkspaceSwitchPresentationTarget(
            workspaceID: workspaceID,
            contentKind: .passive,
            terminalSurfaceID: nil,
            terminalView: nil,
            terminalRendererPresented: false,
            terminalRenderedFrameSequence: 0,
            browserWebView: nil,
            portalPresented: true,
            interactionReady: true,
            requiresInteraction: false
        )
    }

    private func workspaceSwitchRequiresInteraction(
        in window: NSWindow?,
        sourceWorkspaceID: UUID
    ) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        guard !isCommandPalettePresented,
              !fileExplorerState.rightSidebarOwnsInputFocus else {
            return false
        }
        guard let responder = window.firstResponder else { return true }
        if responder === window {
            return true
        }
        guard let sourceWorkspace = tabManager.tabs.first(where: {
            $0.id == sourceWorkspaceID
        }) else {
            return false
        }
        return sourceWorkspace.panels.values.contains { panel in
            panel.ownedFocusIntent(for: responder, in: window) != nil
        }
    }

    private func terminalInteractionIsReady(
        _ panel: TerminalPanel,
        in window: NSWindow?
    ) -> Bool {
        guard let window,
              let responder = window.firstResponder else {
            return false
        }
        return panel.ownedFocusIntent(for: responder, in: window) != nil
    }

    private func selectedWorkspaceInputIsReady(workspaceID: UUID) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              workspace.id == workspaceID,
              let target = workspace.focusedTerminalInputTarget() else {
            return false
        }
        return terminalInteractionIsReady(
            target.panel,
            in: observedWindow ?? tabManager.window
        )
    }

    private func noteSelectedTerminalPortalPresentedIfReady() {
        guard tabManager.workspaceSwitchCoordinator.isMeasuringSwitch,
              let workspace = tabManager.selectedWorkspace,
              let target = workspace.focusedTerminalInputTarget() else {
            return
        }
        noteTerminalPortalPresentedIfReady(target.panel.hostedView)
    }

    private func noteTerminalPortalPresentedIfReady(_ hostedView: GhosttySurfaceScrollView) {
        guard tabManager.workspaceSwitchCoordinator.isMeasuringSwitch,
              let surface = hostedView.surfaceView.terminalSurface,
              surface.tabId == tabManager.selectedTabId else {
            return
        }
        if let owningWindow = observedWindow ?? tabManager.window,
           hostedView.window !== owningWindow {
            return
        }
        guard TerminalWindowPortalRegistry.isPresented(hostedView) else { return }
        tabManager.workspaceSwitchCoordinator.noteTerminalPortalPresented(
            surfaceID: surface.id,
            renderedFrameSequence: hostedView.surfaceView.renderedFrameSequence
        )
        clearWorkspaceSwitchPortalSignalsIfFinished()
    }

    private func clearWorkspaceSwitchPortalSignalsIfFinished() {
        guard !tabManager.workspaceSwitchCoordinator.isMeasuringSwitch else { return }
        workspaceSwitchPortalSignalRouter.clearSources()
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
                .background(CommandPalettePanelHitRegion())
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
                .tint(Color(nsColor: SidebarAppearanceColorResolver().activeForegroundColor(
                    opacity: 1.0,
                    for: windowAppearanceSnapshot.resolvedColorScheme
                )))
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
                let event = NSApp.currentEvent
                if let delta = commandPaletteSelectionDeltaForFieldEditorCommand(commandSelector, event: event),
                   event.map({ contextAwareCommandPaletteSelectionDelta(for: $0) == delta }) ?? true {
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

                if let delta = contextAwareCommandPaletteSelectionDelta(for: event) {
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
        case .workspaceGroup:
            return String(localized: "commandPalette.rename.workspaceGroupInputHint", defaultValue: "Enter a group name. Press Enter to rename, Escape to cancel.")
        }
    }

    private func renameConfirmHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to apply this tab name, or Escape to cancel.")
        case .workspaceGroup:
            return String(localized: "commandPalette.rename.workspaceGroupConfirmHint", defaultValue: "Press Enter to apply this group name, or Escape to cancel.")
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
        commandPaletteTaskStore.cancel(.search)
    }

    private func cancelCommandPaletteSearchIndexBuild() {
        commandPaletteTaskStore.cancel(.searchIndexBuild)
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
        commandPaletteTaskStore.replace(.searchIndexBuild, priority: .userInitiated) {
            let index = CommandPaletteNucleoSearchIndex(entries: entries)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard commandPaletteSearchIndexBuildGeneration == generation,
                      cachedCommandPaletteScope == scope,
                      cachedCommandPaletteFingerprint == fingerprint else {
                    return
                }
                commandPaletteNucleoSearchIndex = index
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

        commandPaletteTaskStore.replace(.search, priority: .userInitiated) {
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
        let directories = [workspace.presentedCurrentDirectory].compactMap { $0 }
        let branches = [workspace.presentedGitBranch?.branch].compactMap { $0 }
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
        let directories = [workspace.reportedPanelDirectory(panelId: panelId)].compactMap { $0 }
        let branches = [workspace.reportedPanelGitBranch(panelId: panelId)?.branch].compactMap { $0 }
        let ports = workspace.surfaceListeningPorts[panelId] ?? []
        return CommandPaletteSwitcherSearchMetadata(
            directories: directories,
            branches: branches,
            ports: ports
        )
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

    static let commandPaletteForkableAgentProbeResultTTL: TimeInterval = 15.0
    static let commandPaletteForkableAgentProbeResultMaximumCount = 64

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
        case .pi:
            return isRemoteTerminal ? .unsupported : .requiresProbe
        case .opencode:
            return snapshot.launchCommand?.launcher == "omo" || isRemoteTerminal ? .supportedWithoutProbe : .requiresProbe
        case .custom:
            if AgentForkSupport.requiresLocalPiFamilyCapabilityProbe(snapshot) {
                return isRemoteTerminal ? .unsupported : .requiresProbe
            }
            return .supportedWithoutProbe
        default:
            return .unsupported
        }
    }

    static func commandPaletteForkSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> String {
        let launchCommand = snapshot.launchCommand
        let launchArguments = launchCommand?.arguments.joined(separator: "\u{1f}") ?? ""
        let launchEnvironment = launchCommand?.environment.map { environment in
            environment.keys.sorted().map { key in
                "\(key)=\(environment[key] ?? "")"
            }.joined(separator: "\u{1f}")
        } ?? ""
        let parts: [String] = [
            snapshot.kind.rawValue,
            snapshot.sessionId,
            snapshot.workingDirectory ?? "",
            isRemoteTerminal ? "remote" : "local",
            launchCommand?.launcher ?? "",
            launchCommand?.executablePath ?? "",
            launchArguments,
            launchCommand?.workingDirectory ?? "",
            launchEnvironment,
            launchCommand?.source ?? "",
            snapshot.forkCommand ?? ""
        ]
        return parts.joined(separator: "\u{1e}")
    }

    static func commandPaletteForkProbeExecutableFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) async -> String {
        await SharedLiveAgentIndex.shared.forkValidationExecutableFingerprint(
            snapshot: snapshot,
            isRemoteContext: isRemoteTerminal
        )
    }

    static func commandPaletteForkProbeExecutableFingerprintValue(
        _ snapshot: SessionRestorableAgentSnapshot,
        isRemoteTerminal: Bool = false
    ) -> String {
        AgentForkSupport.forkValidationExecutableFingerprint(
            snapshot: snapshot,
            isRemoteContext: isRemoteTerminal
        )
    }

    static func commandPaletteForkCacheFingerprint(
        snapshot: SessionRestorableAgentSnapshot,
        fallbackFingerprint: String?,
        isRemoteTerminal: Bool = false
    ) -> String {
        fallbackFingerprint ?? commandPaletteForkSnapshotFingerprint(
            snapshot,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    static func commandPaletteForkAvailabilitySnapshotSource(
        liveIndexSnapshot: SessionRestorableAgentSnapshot?,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        isRemoteTerminal: Bool = false
    ) -> (
        snapshot: SessionRestorableAgentSnapshot,
        snapshotFingerprint: String,
        validationFallbackSnapshot: SessionRestorableAgentSnapshot?,
        validationFallbackFingerprint: String?,
        resultHadFallback: Bool
    )? {
        guard let snapshot = liveIndexSnapshot ?? fallbackSnapshot else {
            return nil
        }
        let usesFallback = liveIndexSnapshot == nil
        let snapshotFingerprint = commandPaletteForkSnapshotFingerprint(
            snapshot,
            isRemoteTerminal: isRemoteTerminal
        )
        return (
            snapshot: snapshot,
            snapshotFingerprint: snapshotFingerprint,
            validationFallbackSnapshot: usesFallback ? fallbackSnapshot : nil,
            validationFallbackFingerprint: usesFallback ? snapshotFingerprint : nil,
            resultHadFallback: usesFallback && fallbackSnapshot != nil
        )
    }

    static func commandPaletteForkableAgentProbeResultIsFresh(
        validatedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let validatedAt else { return true }
        return now.timeIntervalSince(validatedAt) < commandPaletteForkableAgentProbeResultTTL
    }

    static func commandPaletteNextForkableAgentProbeResultExpiry(
        validatedAtByPanelKey: [String: Date],
        now: Date = Date()
    ) -> Date? {
        validatedAtByPanelKey.values
            .map { $0.addingTimeInterval(commandPaletteForkableAgentProbeResultTTL) }
            .filter { $0 > now }
            .min()
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

    static func commandPaletteForkableAgentProbeRejectionMatches(
        panelKey: String,
        rejectedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        expectedSnapshotFingerprint: String?,
        isRemoteTerminal: Bool
    ) -> Bool {
        guard rejectedPanelKeys.contains(panelKey),
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
        cachedResultHadFallback _: Bool,
        panelChanged: Bool,
        cachedResultIsFresh: Bool = true
    ) -> Bool {
        !panelChanged && cachedResultIsFresh && commandPaletteForkableAgentProbeResultMatches(
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
        cachedResultHadFallback _: Bool,
        panelChanged: Bool,
        cachedResultIsFresh: Bool = true
    ) -> Bool {
        panelChanged || !cachedResultIsFresh || !commandPaletteForkableAgentProbeResultMatches(
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

    private func clearCommandPaletteForkableAgentProbeResult(for panelKey: String) {
        commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
        commandPaletteForkableAgentRejectedPanelKeys.remove(panelKey)
        commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentExecutableFingerprintsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentResultHadFallbackByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentValidatedAtByPanelKey.removeValue(forKey: panelKey)
    }

    private func pruneCommandPaletteForkableAgentProbeResults(now: Date = Date()) {
        for (panelKey, validatedAt) in commandPaletteForkableAgentValidatedAtByPanelKey
            where !Self.commandPaletteForkableAgentProbeResultIsFresh(validatedAt: validatedAt, now: now) {
            clearCommandPaletteForkableAgentProbeResult(for: panelKey)
        }
        let cachedPanelKeys = commandPaletteForkableAgentSupportedPanelKeys
            .union(commandPaletteForkableAgentRejectedPanelKeys)
        guard cachedPanelKeys.count > Self.commandPaletteForkableAgentProbeResultMaximumCount else { return }
        let overflowCount = cachedPanelKeys.count - Self.commandPaletteForkableAgentProbeResultMaximumCount
        let oldestPanelKeys = cachedPanelKeys
            .sorted {
                (commandPaletteForkableAgentValidatedAtByPanelKey[$0] ?? .distantPast)
                    < (commandPaletteForkableAgentValidatedAtByPanelKey[$1] ?? .distantPast)
            }
            .prefix(overflowCount)
        for panelKey in oldestPanelKeys {
            clearCommandPaletteForkableAgentProbeResult(for: panelKey)
        }
    }

    private func scheduleCommandPaletteForkableAgentProbeResultExpiryRefresh(now: Date = Date()) {
        commandPaletteForkableAgentProbeResultExpiryScheduler.cancel()
        guard isCommandPalettePresented,
              Self.commandPaletteListScope(for: commandPaletteQuery) == .commands,
              let nextExpiry = Self.commandPaletteNextForkableAgentProbeResultExpiry(
                validatedAtByPanelKey: commandPaletteForkableAgentValidatedAtByPanelKey,
                now: now
              ) else {
            return
        }
        let delay = max(nextExpiry.timeIntervalSince(now), 0.001)
        commandPaletteForkableAgentProbeResultExpiryScheduler.schedule(after: .seconds(delay)) {
            guard isCommandPalettePresented else { return }
            pruneCommandPaletteForkableAgentProbeResults()
            scheduleCommandPaletteResultsRefresh(
                query: commandPaletteQuery,
                preservePendingActivation: true
            )
            scheduleCommandPaletteForkableAgentProbeResultExpiryRefresh()
        }
    }

    private func cancelCommandPaletteForkableAgentProbeResultExpiryRefresh() {
        commandPaletteForkableAgentProbeResultExpiryScheduler.cancel()
    }

    private func refreshCommandPaletteForkableAgentAvailabilityAfterSharedIndexChange(_ notification: Notification) {
        guard isCommandPalettePresented,
              Self.commandPaletteListScope(for: commandPaletteQuery) == .commands else {
            return
        }
        if let panelIdsByWorkspaceId = notification.userInfo?["panelIdsByWorkspaceId"] as? [UUID: Set<UUID>] {
            let changedPanelKeys = panelIdsByWorkspaceId.flatMap { workspaceId, panelIds in
                panelIds.map { panelId in
                    Self.commandPaletteForkableAgentPanelKey(
                        workspaceId: workspaceId,
                        panelId: panelId
                    )
                }
            }
            guard let activePanelKey = commandPaletteForkableAgentActivePanelKey,
                  changedPanelKeys.contains(activePanelKey) else {
                return
            }
        } else if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
           let panelId = notification.userInfo?["panelId"] as? UUID {
            let changedPanelKey = Self.commandPaletteForkableAgentPanelKey(
                workspaceId: workspaceId,
                panelId: panelId
            )
            guard commandPaletteForkableAgentActivePanelKey == changedPanelKey else {
                return
            }
        }
        pruneCommandPaletteForkableAgentProbeResults()
        scheduleCommandPaletteResultsRefresh(
            query: commandPaletteQuery,
            preservePendingActivation: true
        )
        scheduleCommandPaletteForkableAgentProbeResultExpiryRefresh()
    }

    private func refreshCommandPaletteForkableAgentAvailabilityIfNeeded(scope: CommandPaletteListScope) {
        defer {
            scheduleCommandPaletteForkableAgentProbeResultExpiryRefresh()
        }
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
        let allowsAgentContinuation = panelContext.workspace.allowsAgentContinuation(forPanelId: panelId)
        if !allowsAgentContinuation {
            cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
            clearCommandPaletteForkableAgentProbeResult(for: panelKey)
        }
        let fallbackSnapshot = allowsAgentContinuation
            ? panelContext.workspace.restoredAgentSnapshotForContinuation(panelId: panelId)
            : nil
        let liveIndexSnapshot = SharedLiveAgentIndex.shared.snapshotForForkAvailability(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteTerminal
        )
        let liveCandidateSnapshot = SharedLiveAgentIndex.shared.snapshotForForkConversationCandidate(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let liveProbeRejected = liveIndexSnapshot == nil
            && liveCandidateSnapshot != nil
            && SharedLiveAgentIndex.shared.forkSupportProbeRejected(
                workspaceId: workspaceId,
                panelId: panelId,
                isRemoteContext: isRemoteTerminal
            )
        if liveProbeRejected, let liveCandidateSnapshot {
            let liveFingerprint = Self.commandPaletteForkSnapshotFingerprint(
                liveCandidateSnapshot,
                isRemoteTerminal: isRemoteTerminal
            )
            if let cachedFingerprint = commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey],
               cachedFingerprint != liveFingerprint {
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                clearCommandPaletteForkableAgentProbeResult(for: panelKey)
            }
            commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
            commandPaletteForkableAgentRejectedPanelKeys.insert(panelKey)
            commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = liveFingerprint
            commandPaletteForkableAgentExecutableFingerprintsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
            commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] = false
            commandPaletteForkableAgentValidatedAtByPanelKey[panelKey] =
                SharedLiveAgentIndex.shared.forkSupportProbeCompletedAt(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal
                ) ?? Date()
            return
        }
        if liveIndexSnapshot == nil, let liveCandidateSnapshot {
            let liveFingerprint = Self.commandPaletteForkSnapshotFingerprint(
                liveCandidateSnapshot,
                isRemoteTerminal: isRemoteTerminal
            )
            startCommandPaletteForkableAgentAvailabilityProbe(
                panelKey: panelKey,
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackSnapshot: nil,
                fallbackFingerprint: nil,
                snapshotFingerprint: liveFingerprint,
                isRemoteTerminal: isRemoteTerminal
            )
            return
        }

        if let fallbackSnapshot,
           let snapshotSource = Self.commandPaletteForkAvailabilitySnapshotSource(
            liveIndexSnapshot: liveIndexSnapshot,
            fallbackSnapshot: fallbackSnapshot,
            isRemoteTerminal: isRemoteTerminal
           ) {
            if let cachedFingerprint = commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey],
               cachedFingerprint != snapshotSource.snapshotFingerprint {
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                clearCommandPaletteForkableAgentProbeResult(for: panelKey)
            }
            switch Self.commandPaletteSnapshotForkAvailability(
                snapshotSource.snapshot,
                isRemoteTerminal: isRemoteTerminal
            ) {
            case .supportedWithoutProbe:
                let probeResultMatches = Self.commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: snapshotSource.snapshotFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                if probeResultMatches {
                    commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentRejectedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    if snapshotSource.resultHadFallback {
                        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                            Self.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                                cachedResultHadFallback: commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey]
                            )
                    } else {
                        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] = false
                    }
                } else {
                    clearCommandPaletteForkableAgentProbeResult(for: panelKey)
                }
                if panelChanged || !probeResultMatches {
                startCommandPaletteForkableAgentAvailabilityProbe(
                    panelKey: panelKey,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot,
                    fallbackFingerprint: snapshotSource.validationFallbackFingerprint,
                    snapshotFingerprint: snapshotSource.snapshotFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                }
                return
            case .unsupported:
                cancelCommandPaletteForkableAgentAvailabilityProbe(for: panelKey)
                clearCommandPaletteForkableAgentProbeResult(for: panelKey)
                return
            case .requiresProbe:
                let probeResultMatches = Self.commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: snapshotSource.snapshotFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                let probeRejectionMatches = Self.commandPaletteForkableAgentProbeRejectionMatches(
                    panelKey: panelKey,
                    rejectedPanelKeys: commandPaletteForkableAgentRejectedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: snapshotSource.snapshotFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                )
                let cachedResultHadFallback = commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] == true
                let cachedResultIsFresh = Self.commandPaletteForkableAgentProbeResultIsFresh(
                    validatedAt: commandPaletteForkableAgentValidatedAtByPanelKey[panelKey]
                )
                let sharedProbeAccepted = SharedLiveAgentIndex.shared.forkSupportProbeAccepted(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                )
                let sharedProbeRejected = SharedLiveAgentIndex.shared.forkSupportProbeRejected(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal,
                    fallbackSnapshot: snapshotSource.validationFallbackSnapshot
                )
                let shouldClearBeforeProbe = probeResultMatches && Self.commandPaletteShouldClearForkableAgentProbeResultBeforeProbe(
                    panelKey: panelKey,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: snapshotSource.snapshotFingerprint,
                    isRemoteTerminal: isRemoteTerminal,
                    cachedResultHadFallback: cachedResultHadFallback,
                    panelChanged: panelChanged,
                    cachedResultIsFresh: cachedResultIsFresh
                )
                if probeResultMatches && !shouldClearBeforeProbe {
                    if snapshotSource.resultHadFallback {
                        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                            Self.commandPaletteForkMatchedFallbackProbeResultHadFallback(
                                cachedResultHadFallback: commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey]
                            )
                    } else {
                        commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] = false
                    }
                }
                if probeResultMatches && cachedResultIsFresh && !panelChanged && sharedProbeAccepted {
                    return
                }
                if probeRejectionMatches && cachedResultIsFresh && !panelChanged && sharedProbeRejected {
                    return
                }
                if shouldClearBeforeProbe
                    || (probeResultMatches && !sharedProbeAccepted)
                    || (probeRejectionMatches && !sharedProbeRejected) {
                    clearCommandPaletteForkableAgentProbeResult(for: panelKey)
                }
                    startCommandPaletteForkableAgentAvailabilityProbe(
                        panelKey: panelKey,
                        workspaceId: workspaceId,
                        panelId: panelId,
                        fallbackSnapshot: snapshotSource.validationFallbackSnapshot,
                        fallbackFingerprint: snapshotSource.validationFallbackFingerprint,
                        snapshotFingerprint: snapshotSource.snapshotFingerprint,
                        isRemoteTerminal: isRemoteTerminal
                    )
                return
            }
        }

        let cachedResultHadFallback = commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] == true
        let cachedResultIsFresh = Self.commandPaletteForkableAgentProbeResultIsFresh(
            validatedAt: commandPaletteForkableAgentValidatedAtByPanelKey[panelKey]
        )
        let probeRejectionMatches = Self.commandPaletteForkableAgentProbeRejectionMatches(
            panelKey: panelKey,
            rejectedPanelKeys: commandPaletteForkableAgentRejectedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal
        )
        let sharedProbeAccepted = SharedLiveAgentIndex.shared.forkSupportProbeAccepted(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteTerminal
        )
        let sharedProbeRejected = SharedLiveAgentIndex.shared.forkSupportProbeRejected(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteContext: isRemoteTerminal
        )
        if Self.commandPaletteShouldReuseForkableAgentProbeResult(
            panelKey: panelKey,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            expectedSnapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal,
            cachedResultHadFallback: cachedResultHadFallback,
            panelChanged: panelChanged,
            cachedResultIsFresh: cachedResultIsFresh
        ) && sharedProbeAccepted {
            return
        }
        if probeRejectionMatches && cachedResultIsFresh && !panelChanged && sharedProbeRejected {
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
            panelChanged: panelChanged,
            cachedResultIsFresh: cachedResultIsFresh
        )
            || (Self.commandPaletteForkableAgentProbeResultMatches(
                panelKey: panelKey,
                supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
                expectedSnapshotFingerprint: nil,
                isRemoteTerminal: isRemoteTerminal
            ) && !sharedProbeAccepted)
            || (probeRejectionMatches && !sharedProbeRejected) {
            clearCommandPaletteForkableAgentProbeResult(for: panelKey)
        }
        startCommandPaletteForkableAgentAvailabilityProbe(
            panelKey: panelKey,
            workspaceId: workspaceId,
            panelId: panelId,
            fallbackSnapshot: nil,
            fallbackFingerprint: nil,
            snapshotFingerprint: nil,
            isRemoteTerminal: isRemoteTerminal
        )
    }

    private func startCommandPaletteForkableAgentAvailabilityProbe(
        panelKey: String,
        workspaceId: UUID,
        panelId: UUID,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        fallbackFingerprint: String?,
        snapshotFingerprint: String?,
        isRemoteTerminal: Bool
    ) {
        let probeFingerprint = "\(snapshotFingerprint ?? fallbackFingerprint ?? "")\u{1f}\(isRemoteTerminal ? "remote" : "local")"
        let taskKey = CommandPaletteTaskKey.forkableAgentAvailability(panelKey)
        if commandPaletteTaskStore.contains(taskKey) {
            guard commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] != probeFingerprint else { return }
            commandPaletteTaskStore.cancel(taskKey)
            commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
        }
        let probeID = UUID()
        commandPaletteForkableAgentProbeIDsByPanelKey[panelKey] = probeID
        commandPaletteForkableAgentProbeFingerprintsByPanelKey[panelKey] = probeFingerprint

        commandPaletteTaskStore.replaceOnMainActor(taskKey) {
            let sharedIndex = SharedLiveAgentIndex.shared
            if let fallbackSnapshot {
                await sharedIndex.refreshForkAvailabilityNow(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal
                )
                guard !Task.isCancelled else { return }
                let liveAcceptedSnapshot = sharedIndex.snapshotForForkAvailability(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal
                )
                let liveCandidateSnapshot = sharedIndex.snapshotForForkConversationCandidate(
                    workspaceId: workspaceId,
                    panelId: panelId
                )
                if liveAcceptedSnapshot == nil, liveCandidateSnapshot == nil {
                    await sharedIndex.refreshForkAvailabilityNow(
                        workspaceId: workspaceId,
                        panelId: panelId,
                        isRemoteContext: isRemoteTerminal,
                        fallbackSnapshot: fallbackSnapshot
                    )
                }
            } else {
                await sharedIndex.refreshForkAvailabilityNow(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal
                )
            }
            guard !Task.isCancelled else { return }
            let indexEntry = sharedIndex.index?.entry(workspaceId: workspaceId, panelId: panelId)
            let indexSnapshot = sharedIndex.snapshotForForkAvailability(
                workspaceId: workspaceId,
                panelId: panelId,
                isRemoteContext: isRemoteTerminal
            )
            let liveCandidateSnapshot = sharedIndex.snapshotForForkConversationCandidate(
                workspaceId: workspaceId,
                panelId: panelId
            )
            let rejectedIndexSnapshot = indexSnapshot == nil
                && liveCandidateSnapshot != nil
                && sharedIndex.forkSupportProbeRejected(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal
                )
                ? liveCandidateSnapshot
                : nil
            let snapshot = indexSnapshot ?? rejectedIndexSnapshot ?? fallbackSnapshot
            let validationFallbackSnapshot = indexSnapshot == nil && rejectedIndexSnapshot == nil
                ? fallbackSnapshot
                : nil
            let cacheFallbackFingerprint = validationFallbackSnapshot == nil ? nil : fallbackFingerprint
            let snapshotAvailability: CommandPaletteForkSnapshotAvailability
            if let snapshot {
                snapshotAvailability = Self.commandPaletteSnapshotForkAvailability(
                    snapshot,
                    isRemoteTerminal: isRemoteTerminal
                )
            } else {
                snapshotAvailability = .unsupported
            }
            let requiresCapabilityProbe = snapshotAvailability == .requiresProbe
            let sharedProbeAccepted: Bool
            let sharedProbeCompletedAt: Date?
            let executableFingerprint: String?
            if rejectedIndexSnapshot != nil {
                sharedProbeAccepted = false
                sharedProbeCompletedAt = sharedIndex.forkSupportProbeCompletedAt(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteContext: isRemoteTerminal
                )
                executableFingerprint = nil
            } else {
                switch snapshotAvailability {
                case .supportedWithoutProbe:
                    sharedProbeAccepted = true
                    sharedProbeCompletedAt = nil
                    executableFingerprint = nil
                case .requiresProbe:
                    let probeAccepted = sharedIndex.forkSupportProbeAccepted(
                        workspaceId: workspaceId,
                        panelId: panelId,
                        isRemoteContext: isRemoteTerminal,
                        fallbackSnapshot: validationFallbackSnapshot
                    )
                    let validationExecutableFingerprint = sharedIndex.forkSupportProbeExecutableFingerprint(
                        workspaceId: workspaceId,
                        panelId: panelId,
                        isRemoteContext: isRemoteTerminal,
                        fallbackSnapshot: validationFallbackSnapshot
                    )
                    sharedProbeAccepted = probeAccepted && validationExecutableFingerprint != nil
                    sharedProbeCompletedAt = sharedIndex.forkSupportProbeCompletedAt(
                        workspaceId: workspaceId,
                        panelId: panelId,
                        isRemoteContext: isRemoteTerminal,
                        fallbackSnapshot: validationFallbackSnapshot
                    )
                    executableFingerprint = validationExecutableFingerprint
                case .unsupported:
                    sharedProbeAccepted = false
                    sharedProbeCompletedAt = nil
                    executableFingerprint = nil
                }
            }
            let supportsFork = sharedProbeAccepted
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
                var acceptedIndexSnapshot = validationFallbackSnapshot == nil ? indexSnapshot : nil
                var acceptedSnapshot = snapshot
                if let currentContext = focusedPanelContext,
                   currentContext.workspace.id == workspaceId,
                   currentContext.panelId == panelId {
                    if let indexEntry {
                        currentContext.workspace.reconcileCompletedRestoredAgent(
                            panelId: panelId,
                            observation: indexEntry
                        )
                    }
                    if !currentContext.workspace.allowsAgentContinuation(forPanelId: panelId) {
                        acceptedIndexSnapshot = nil
                        acceptedSnapshot = nil
                    }
                }
                if validationFallbackSnapshot != nil,
                   let fallbackFingerprint,
                   let currentContext = focusedPanelContext,
                   currentContext.workspace.id == workspaceId,
                   currentContext.panelId == panelId,
                   let currentFallbackSnapshot = currentContext.workspace.restoredAgentSnapshotForContinuation(panelId: panelId),
                   Self.commandPaletteForkSnapshotFingerprint(
                    currentFallbackSnapshot,
                    isRemoteTerminal: isRemoteTerminal
                    ) != fallbackFingerprint {
                    commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    return
                }
                let acceptedSnapshotRequiresProbe = acceptedSnapshot.map {
                    Self.commandPaletteSnapshotForkAvailability(
                        $0,
                        isRemoteTerminal: isRemoteTerminal
                    ) == .requiresProbe
                } ?? false
                let wasSupported = commandPaletteForkableAgentSupportedPanelKeys.contains(panelKey)
                let hadCachedSnapshot = commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] != nil
                let shouldRefreshResults: Bool
                if supportsFork && sharedProbeAccepted, let acceptedSnapshot {
                    shouldRefreshResults = !wasSupported
                    commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentRejectedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = acceptedSnapshot
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkCacheFingerprint(
                        snapshot: acceptedSnapshot,
                        fallbackFingerprint: acceptedIndexSnapshot == nil ? cacheFallbackFingerprint : nil,
                        isRemoteTerminal: isRemoteTerminal
                    )
                    if let executableFingerprint {
                        commandPaletteForkableAgentExecutableFingerprintsByPanelKey[panelKey] = executableFingerprint
                    } else {
                        commandPaletteForkableAgentExecutableFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    }
                    commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                        acceptedIndexSnapshot == nil && cacheFallbackFingerprint != nil
                    if acceptedSnapshotRequiresProbe {
                        commandPaletteForkableAgentValidatedAtByPanelKey[panelKey] =
                            sharedProbeCompletedAt ?? Date()
                    } else {
                        commandPaletteForkableAgentValidatedAtByPanelKey.removeValue(forKey: panelKey)
                    }
                } else {
                    shouldRefreshResults = wasSupported || hadCachedSnapshot
                    commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                    commandPaletteForkableAgentRejectedPanelKeys.insert(panelKey)
                    commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                    commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = if let acceptedSnapshot {
                        Self.commandPaletteForkCacheFingerprint(
                            snapshot: acceptedSnapshot,
                            fallbackFingerprint: acceptedIndexSnapshot == nil ? cacheFallbackFingerprint : nil,
                            isRemoteTerminal: isRemoteTerminal
                        )
                    } else {
                        cacheFallbackFingerprint ?? ""
                    }
                    if let executableFingerprint {
                        commandPaletteForkableAgentExecutableFingerprintsByPanelKey[panelKey] = executableFingerprint
                    } else {
                        commandPaletteForkableAgentExecutableFingerprintsByPanelKey.removeValue(forKey: panelKey)
                    }
                    commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteTerminal
                    commandPaletteForkableAgentResultHadFallbackByPanelKey[panelKey] =
                        acceptedIndexSnapshot == nil && cacheFallbackFingerprint != nil
                    if requiresCapabilityProbe {
                        commandPaletteForkableAgentValidatedAtByPanelKey[panelKey] =
                            sharedProbeCompletedAt ?? Date()
                    } else {
                        commandPaletteForkableAgentValidatedAtByPanelKey.removeValue(forKey: panelKey)
                    }
                }
                commandPaletteForkableAgentProbeIDsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeValue(forKey: panelKey)
                scheduleCommandPaletteForkableAgentProbeResultExpiryRefresh()
                if shouldRefreshResults,
                   isCommandPalettePresented,
                   commandPaletteForkableAgentActivePanelKey == panelKey {
                    scheduleCommandPaletteResultsRefresh(
                        query: commandPaletteQuery
                    )
                }
            }
        }
    }

    private func cancelCommandPaletteForkableAgentAvailabilityProbe() {
        commandPaletteTaskStore.cancel(where: { key in
            if case .forkableAgentAvailability = key {
                return true
            }
            return false
        })
        commandPaletteForkableAgentProbeIDsByPanelKey.removeAll()
        commandPaletteForkableAgentProbeFingerprintsByPanelKey.removeAll()
    }

    private func cancelCommandPaletteForkableAgentAvailabilityProbe(for panelKey: String) {
        commandPaletteTaskStore.cancel(.forkableAgentAvailability(panelKey))
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
        snapshot.setBool(CommandPaletteContextKeys.workspaceMinimalModeEnabled, currentIsMinimalMode)
        snapshot.setBool(CommandPaletteContextKeys.sidebarMatchTerminalBackground, sidebarMatchTerminalBackground)
        snapshot.setBool(CommandPaletteContextKeys.browserDisabled, BrowserAvailabilitySettings.isDisabled())
        snapshot.setBool(CommandPaletteContextKeys.browserManagedByPolicy, BrowserAvailabilitySettings.isManagedByPolicy)
        snapshot.setBool(CommandPaletteContextKeys.mobileRemoteControlManagedByPolicy, MobileRemoteControlPolicy.isDisabled)
        snapshot.setBool(CommandPaletteContextKeys.computerUseUXEnabled, featureFlags.isComputerUseUXEnabled)
        if let auth = AppDelegate.shared?.auth {
            snapshot.setBool(CommandPaletteContextKeys.authSignedIn, auth.accountFlow.isAuthenticated)
            snapshot.setBool(CommandPaletteContextKeys.proUpgradeEnabled, CmuxFeatureFlags.shared.isProUpgradeUIEnabled)
            snapshot.setBool(CommandPaletteContextKeys.authWorking, auth.accountFlow.isWorkingOnAuth)
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
                (AppDelegate.shared?.focusedDockStoreForShortcut(
                    preferredWindow: observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
                )?.bonsplitController.allPaneIds.count ?? workspace.bonsplitController.allPaneIds.count) > 1
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

        if let browserTarget = commandPaletteBrowserActionTarget,
           let app = AppDelegate.shared,
           let dock = app.dock(resolving: browserTarget),
           let browserPanel = dock.browserPanel(
               for: browserTarget.panelId
           ),
           let tabId = dock.surfaceId(
               forPanelId: browserTarget.panelId
           ),
           let tab = dock.bonsplitController.tab(tabId) {
                snapshot.setBool(
                    CommandPaletteContextKeys.hasFocusedPanel,
                    true
                )
                snapshot.setString(
                    CommandPaletteContextKeys.panelName,
                    tab.title
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelIsBrowser,
                    true
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelBrowserFocusModeActive,
                    browserPanel.isBrowserFocusModeActive
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelBrowserOmnibarVisible,
                    browserPanel.isOmnibarVisible
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelHasPane,
                    dock.paneId(forPanelId: browserTarget.panelId) != nil
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelSupportsDeepLinks,
                    false
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelHasCustomName,
                    tab.hasCustomTitle
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelShouldPin,
                    !tab.isPinned
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelCanMoveToNewWorkspace,
                    dock.panels.count > 1
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.workspaceHasSplits,
                    dock.bonsplitController.allPaneIds.count > 1
                )
                snapshot.setBool(
                    CommandPaletteContextKeys.panelHasUnread,
                    dock.panelIsUnread(browserTarget.panelId)
                )
        } else if let panelContext = focusedPanelContext {
            let workspace = panelContext.workspace
            let panelId = panelContext.panelId
            let panelIsTerminal = panelContext.panel.panelType == .terminal
            let panelIsRemoteTerminal = workspace.isRemoteTerminalSurface(panelId)
            snapshot.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            snapshot.setString(CommandPaletteContextKeys.panelName, panelDisplayName(workspace: workspace, panelId: panelId, fallback: panelContext.panel.displayTitle))
            snapshot.setBool(CommandPaletteContextKeys.panelIsBrowser, panelContext.panel.panelType == .browser)
            snapshot.setBool(CommandPaletteContextKeys.panelIsSimulator, panelContext.panel.panelType == .simulator)
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
                CommandPaletteContextKeys.panelIsFilePreviewTextEditor,
                (panelContext.panel as? FilePreviewPanel)?.previewMode == .text
            )
            snapshot.setBool(
                CommandPaletteContextKeys.panelBrowserOmnibarVisible,
                (panelContext.panel as? BrowserPanel)?.isOmnibarVisible ?? true
            )
            snapshot.setBool(CommandPaletteContextKeys.panelIsTerminal, panelIsTerminal)
            snapshot.setBool(CommandPaletteContextKeys.panelHasPane, workspace.paneId(forPanelId: panelId) != nil)
            snapshot.setBool(
                CommandPaletteContextKeys.panelSupportsDeepLinks,
                true
            )
            let allowsAgentContinuation = workspace.allowsAgentContinuation(forPanelId: panelId)
            let fallbackForkableSnapshot = workspace.restoredAgentSnapshotForContinuation(panelId: panelId)
            let forkablePanelKey = Self.commandPaletteForkableAgentPanelKey(
                workspaceId: workspace.id,
                panelId: panelId
            )
            snapshot.setBool(
                CommandPaletteContextKeys.panelHasForkableAgent,
                Self.commandPalettePanelHasForkableAgent(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
                    supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                    liveIndexSnapshot: SharedLiveAgentIndex.shared.snapshotForForkAvailability(
                        workspaceId: workspace.id,
                        panelId: panelId,
                        isRemoteContext: panelIsRemoteTerminal
                    ),
                    fallbackSnapshot: fallbackForkableSnapshot,
                    cachedSnapshot: commandPaletteForkableAgentSnapshotsByPanelKey[forkablePanelKey],
                    isRemoteTerminal: panelIsRemoteTerminal,
                    allowsAgentContinuation: allowsAgentContinuation
                )
            )
            snapshot.setBool(CommandPaletteContextKeys.panelHasCustomName, workspace.panelCustomTitles[panelId] != nil)
            snapshot.setBool(CommandPaletteContextKeys.panelShouldPin, !workspace.isPanelPinned(panelId))
            snapshot.setBool(CommandPaletteContextKeys.panelCanMoveToNewWorkspace, workspace.panels.count > 1)
            snapshot.setBool(
                CommandPaletteContextKeys.panelHasUnread,
                workspace.panelIsUnread(panelId)
            )

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

    /// Search keywords for the mobile pairing command palette entry.
    ///
    /// Kept as a single source of truth so the contribution and its behavioral
    /// test agree on what queries (e.g. `ios`, `ipados`) must surface the
    /// command. These are platform/technical terms that read the same across
    /// locales, so they are not localized.
    static let commandPaletteMobileConnectKeywords: [String] = [
        "tailscale", "iroh", "mobile", "connect", "pair", "pairing", "device",
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
        contributions.append(contentsOf: Self.commandPaletteCloudCommandContributions())
        contributions.append(contentsOf: Self.commandPaletteComputerUseContributions())

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
        contributions.append(contentsOf: Self.commandPaletteNewAgentChatContributions())
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
        if CmuxFeatureFlags.shared.isSimulatorEnabled {
            contributions.append(.newSimulatorPane)
        }
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
                commandId: "palette.reopenClosedWorkspace",
                title: constant(String(localized: "menu.history.reopenClosedWorkspace", defaultValue: "Reopen Closed Workspace")),
                subtitle: constant(String(localized: "menu.history.title", defaultValue: "History")),
                keywords: ["reopen", "closed", "recently", "history", "workspace", "project"]
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
                title: constant(
                    String(localized: "command.mobileConnect.title", defaultValue: "Open Mobile Pairing")
                ),
                subtitle: constant(String(localized: "command.mobileConnect.subtitle", defaultValue: "Mobile")),
                keywords: Self.commandPaletteMobileConnectKeywords,
                when: { !$0.bool(CommandPaletteContextKeys.mobileRemoteControlManagedByPolicy) }
            )
        )
        contributions.append(contentsOf: Self.commandPaletteAuthCommandContributions() + Self.commandPaletteProCommandContributions())
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
                when: {
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                        && !$0.bool(CommandPaletteContextKeys.browserManagedByPolicy)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableBrowser",
                title: constant(String(localized: "command.enableBrowser.title", defaultValue: "Enable cmux Browser")),
                subtitle: constant(String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "enable", "embedded", "open"],
                when: {
                    $0.bool(CommandPaletteContextKeys.browserDisabled)
                        && !$0.bool(CommandPaletteContextKeys.browserManagedByPolicy)
                }
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
        contributions.append(contentsOf: WorkspaceTodoPaletteCommands.contributions(workspaceSubtitle: workspaceSubtitle))
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
        appendSavedLayoutCommandContributions(to: &contributions, workspaceSubtitle: workspaceSubtitle)

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
            contentsOf: Self.commandPaletteSurfaceNavigationContributions()
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
        Self.appendViewZoomCommandContributions(to: &contributions, panelSubtitle: panelSubtitle)
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
                commandId: "palette.toggleFullWidthTab",
                title: constant(String(localized: "command.toggleFullWidthTab.title", defaultValue: "Toggle Full Width Tab")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["full", "width", "tab", "title", "header", "solo"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.hasFocusedPanel) &&
                    context.bool(CommandPaletteContextKeys.panelHasPane)
                }
            )
        )
        contributions.append(contentsOf: paneSizingContributions(subtitle: workspaceSubtitle))

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
        let browserTarget = commandPaletteBrowserActionTarget
        let browserDispatcher = AppDelegate.shared.map {
            BrowserActionDispatcher(appDelegate: $0)
        }
        let dockBrowserStore = browserTarget.flatMap {
            AppDelegate.shared?.dock(resolving: $0)
        }
        let dockBrowserTarget = dockBrowserStore == nil ? nil : browserTarget
        let performBrowserAction: (BrowserAction) -> Bool = {
            action in
            guard let browserTarget, let browserDispatcher else {
                return false
            }
            return browserDispatcher.perform(action, on: browserTarget)
        }

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
                _ = tabManager.acquireOptionalWorkspaceIfActive {
                    AppDelegate.shared?.performNewBrowserWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "palette.newBrowserWorkspace"
                    )
                }
            }
        }
        registerAgentChatCommandPaletteHandler(&registry)
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
                    _ = tabManager.acquireOptionalWorkspaceIfActive {
                        tabManager.addWorkspaceIfActive(workingDirectory: url.path)
                    }
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
            if let dockBrowserStore, let browserTarget {
                guard let paneId = dockBrowserStore.paneId(
                    forPanelId: browserTarget.panelId
                ), let panelId = dockBrowserStore.newSurface(
                    kind: .terminal,
                    inPane: paneId,
                    sourcePanelId: browserTarget.panelId,
                    focus: false
                ) else {
                    NSSound.beep()
                    return
                }
                dockBrowserStore.focusPanelFromDockInteraction(
                    panelId,
                    window: AppDelegate.shared?.mainWindow(for: windowId)
                )
                return
            }
            if !executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newTerminal.configID) {
                tabManager.newSurface()
            }
        }
        registry.register(commandId: "palette.newBrowserTab") {
            if let dockBrowserStore, let browserTarget {
                Task { @MainActor in
                    await Task.yield()
                    guard let paneId = dockBrowserStore.paneId(
                        forPanelId: browserTarget.panelId
                    ),
                    let panelId = dockBrowserStore.newSurface(
                        kind: .browser,
                        inPane: paneId,
                        sourcePanelId: browserTarget.panelId,
                        focus: false
                    ) else {
                        NSSound.beep()
                        return
                    }
                    dockBrowserStore.focusPanelFromDockInteraction(
                        panelId,
                        window: AppDelegate.shared?.mainWindow(for: windowId)
                    )
                }
                return
            }
            if executeConfiguredAction(id: CmuxSurfaceTabBarBuiltInAction.newBrowser.configID) {
                return
            }
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
            }
        }
        registry.registerNewSimulatorPane(tabManager: tabManager, windowId: windowId)
        registry.register(commandId: "palette.closeTab") {
            if let dockBrowserStore, let browserTarget {
                guard dockBrowserStore.containsPanel(
                    browserTarget.panelId
                ) else {
                    NSSound.beep()
                    return
                }
                _ = dockBrowserStore.closePanel(
                    browserTarget.panelId,
                    force: false
                )
                return
            }
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
            if let dockBrowserStore {
                if !dockBrowserStore.performShortcutCommand(
                    .reopenClosedPanel
                ) {
                    NSSound.beep()
                }
                return
            }
            if let appDelegate = AppDelegate.shared {
                _ = appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: tabManager)
            } else {
                _ = tabManager.reopenMostRecentlyClosedItem()
            }
        }
        registry.register(commandId: "palette.reopenClosedWorkspace") {
            if let appDelegate = AppDelegate.shared {
                _ = appDelegate.reopenMostRecentlyClosedWorkspace(preferredTabManager: tabManager)
            } else {
                _ = tabManager.reopenMostRecentlyClosedWorkspace()
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
            UserDefaults.standard.set(
                WorkspacePresentationModeSettings.Mode.minimal.rawValue,
                forKey: WorkspacePresentationModeSettings.modeKey
            )
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            UserDefaults.standard.set(
                WorkspacePresentationModeSettings.Mode.standard.rawValue,
                forKey: WorkspacePresentationModeSettings.modeKey
            )
        }
        registerViewCommandHandlers(&registry)
        registerCanvasCommandHandlers(&registry)
        registerCloudCommandHandlers(&registry)
        registerComputerUseCommandPaletteHandlers(&registry)
        registerSavedLayoutCommandHandlers(&registry)
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
            _ = AppDelegate.shared?.performMobileConnectWorkspaceAction(
                tabManager: tabManager,
                preferredWindow: observedWindow,
                enforceFeatureFlag: false,
                debugSource: "palette.mobileConnect"
            )
        }
        registerAuthCommandHandlers(&registry)
        registerProCommandHandlers(&registry)
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
            guard !BrowserAvailabilitySettings.isManagedByPolicy else { return }
            BrowserAvailabilitySettings.setDisabled(true)
        }
        registry.register(commandId: "palette.enableBrowser") {
            guard !BrowserAvailabilitySettings.isManagedByPolicy else { return }
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
            tabManager.moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            tabManager.moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: tabManager)
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
        registerIdentifierCopyCommandHandlers(
            &registry,
            dockTarget: dockBrowserTarget
        )

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            if let dockBrowserStore, let browserTarget {
                if !dockBrowserStore.setDockPanelCustomTitle(
                    panelId: browserTarget.panelId,
                    title: nil
                ) {
                    NSSound.beep()
                }
                return
            }
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.moveTabToNewWorkspace") {
            if dockBrowserStore != nil {
                guard performBrowserAction(.moveToNewWorkspace) else {
                    NSSound.beep()
                    return
                }
                return
            }
            guard moveFocusedPanelToNewWorkspace() else { NSSound.beep(); return }
        }
        registry.register(commandId: "palette.toggleTabPin") {
            if let dockBrowserStore, let browserTarget {
                guard let tabId = dockBrowserStore.surfaceId(
                    forPanelId: browserTarget.panelId
                ), let tab = dockBrowserStore.bonsplitController.tab(
                    tabId
                ) else {
                    NSSound.beep()
                    return
                }
                if !dockBrowserStore.setDockPanelPinned(
                    panelId: browserTarget.panelId,
                    pinned: !tab.isPinned
                ) {
                    NSSound.beep()
                }
                return
            }
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
            if let dockBrowserStore, let browserTarget {
                if !dockBrowserStore.togglePanelUnread(
                    browserTarget.panelId
                ) {
                    NSSound.beep()
                }
                return
            }
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            if !panelContext.workspace.togglePanelUnread(
                panelContext.panelId
            ) {
                NSSound.beep()
            }
        }
        registerSurfaceNavigationCommandHandlers(
            &registry,
            dock: dockBrowserStore
        ) { observedWindow }
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
            _ = performBrowserAction(.back)
        }
        registry.register(commandId: "palette.browserForward") {
            _ = performBrowserAction(.forward)
        }
        registry.register(commandId: "palette.browserReload") {
            _ = performBrowserAction(.reload)
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !performBrowserAction(.openInDefaultBrowser) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !performBrowserAction(.focusAddressBar) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusMode") {
            if !performBrowserAction(
                .toggleFocusMode(reason: "commandPalette")
            ) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleOmnibar") {
            if !performBrowserAction(.toggleOmnibar) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !performBrowserAction(.toggleDeveloperTools) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !performBrowserAction(.showJavaScriptConsole) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserReactGrab") {
            if !performBrowserAction(.toggleReactGrab) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            let handled = browserTarget != nil
                ? performBrowserAction(.zoomIn)
                : tabManager.zoomInFocusedBrowserOrTextFilePreview()
            if !handled {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            let handled = browserTarget != nil
                ? performBrowserAction(.zoomOut)
                : tabManager.zoomOutFocusedBrowserOrTextFilePreview()
            if !handled {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            let handled = browserTarget != nil
                ? performBrowserAction(.resetZoom)
                : tabManager.resetZoomFocusedBrowserOrTextFilePreview()
            if !handled {
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
            _ = performBrowserAction(.split(.right))
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = performBrowserAction(.split(.down))
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            _ = performBrowserAction(.duplicateRight)
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
        registry.register(commandId: "palette.toggleFullWidthTab") {
            if let dockBrowserStore, let browserTarget {
                if !dockBrowserStore.toggleDockFullWidthTab(
                    panelId: browserTarget.panelId
                ) {
                    NSSound.beep()
                }
                return
            }
            if !tabManager.toggleFocusedFullWidthTab() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            if let dockBrowserStore {
                if !dockBrowserStore.performShortcutCommand(
                    .equalizeSplits
                ) {
#if DEBUG
                    cmuxDebugLog(
                        "palette.equalizeSplits result=noSplitOrFailed " +
                            "dock=\(dockBrowserStore.workspaceId)"
                    )
#endif
                }
                return
            }
            if let workspace = tabManager.selectedWorkspace, !tabManager.equalizeSplits(tabId: workspace.id) {
#if DEBUG
                cmuxDebugLog("palette.equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
#endif
            }
        }
        registerPaneResizeHandlers(&registry) { observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow }

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
              target.intent == .terminal(.surface) else { return false }
        let terminalPanel: TerminalPanel?
        switch target.host {
        case .workspace(let workspaceId):
            terminalPanel = tabManager.tabs.first(where: { $0.id == workspaceId })?
                .panels[target.panelId] as? TerminalPanel
        case .workspaceDock, .windowDock:
            let dock = AppDelegate.shared?.dock(
                resolving: BrowserActionTarget(
                    host: target.host,
                    panelId: target.panelId
                )
            )
            terminalPanel = dock?.panels[target.panelId] as? TerminalPanel
        }
        guard let terminalPanel else { return false }
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
        commandPaletteFocusRestoreCoordinator.clear()
        let browserTarget = AppDelegate.shared?.focusedBrowserActionTarget(
            preferredWindow: observedWindow ?? NSApp.keyWindow
                ?? NSApp.mainWindow
        )
        commandPaletteBrowserActionTarget = browserTarget
        if let browserTarget,
           let browserPanel = AppDelegate.shared?.browserPanel(
               resolving: browserTarget
           ) {
            commandPaletteRestoreFocusTarget =
                CommandPaletteRestoreFocusTarget(
                    host: browserTarget.host,
                    panelId: browserTarget.panelId,
                    intent: browserPanel.captureFocusIntent(
                        in: observedWindow
                    )
                )
        } else if let panelContext = focusedPanelContext {
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
        pruneCommandPaletteForkableAgentProbeResults()
        scheduleCommandPaletteForkableAgentProbeResultExpiryRefresh()
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

    private func dismissCommandPalette(
        for dismissal: CommandPaletteInteractionDismissal,
        in window: NSWindow
    ) {
        if dismissal == .mainMenuBeganTracking {
            // Menu tracking keeps this window key. Restore the saved panel before
            // entering the nested menu loop; a selected command can still replace it.
            dismissCommandPalette(restoreFocus: true)
            return
        }
        guard case .pointer(let event) = dismissal, event.isInObservedWindow else {
            dismissCommandPalette(restoreFocus: false)
            return
        }

        // Other local monitors have no ordering contract. Reconcile a clicked
        // terminal/browser target directly after hiding the overlay; the returned
        // mouse-down can still replace this provisional focus during dispatch.
        let clickedFocusTarget = commandPalettePointerFocusTarget(
            atWindowPoint: event.locationInWindow,
            in: window
        )
        dismissCommandPalette(
            restoreFocus: true,
            preferredFocusTarget: clickedFocusTarget
        )
    }

    private func commandPalettePointerFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
            return CommandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                intent: workspace.panels[panelId]?.captureFocusIntent(in: window) ?? .terminal(.surface)
            )
        }

        guard let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window) else {
            return nil
        }
        if let app = AppDelegate.shared,
           let browserPanel = app.browserPanel(owning: webView),
           let target = app.browserActionTarget(for: browserPanel) {
            return CommandPaletteRestoreFocusTarget(
                host: target.host,
                panelId: target.panelId,
                intent: browserPanel.captureFocusIntent(in: window)
            )
        }
        let selectedWorkspaceId = tabManager.selectedTabId
        let orderedWorkspaces = tabManager.tabs.filter { $0.id == selectedWorkspaceId }
            + tabManager.tabs.filter { $0.id != selectedWorkspaceId }
        for workspace in orderedWorkspaces {
            for (panelId, panel) in workspace.panels {
                guard let browserPanel = panel as? BrowserPanel, browserPanel.webView === webView else {
                    continue
                }
                return CommandPaletteRestoreFocusTarget(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    intent: panel.captureFocusIntent(in: window)
                )
            }
        }
        return nil
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
        cancelCommandPaletteForkableAgentProbeResultExpiryRefresh()
        commandPaletteForkableAgentActivePanelKey = nil
        pruneCommandPaletteForkableAgentProbeResults()
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
        commandPaletteBrowserActionTarget = nil
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

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        commandPaletteFocusRestoreCoordinator.request(target: target)
        attemptCommandPaletteFocusRestoreIfNeeded()
    }

    private func attemptCommandPaletteFocusRestoreIfNeeded(focusTransactionId: UUID? = nil) {
        guard !isCommandPalettePresented else { return }
        guard let target = commandPaletteFocusRestoreCoordinator.pendingTarget else { return }

        let activeDock = AppDelegate.shared?.focusedDockStoreForShortcut(
            preferredWindow: observedWindow
        )
        let currentHost: PanelHost?
        if let activeDock, let app = AppDelegate.shared {
            currentHost = app.panelHost(for: activeDock)
        } else {
            currentHost = tabManager.selectedTabId.map(PanelHost.workspace)
        }
        let focusedPanelId = activeDock?.focusedPanelId
            ?? tabManager.selectedWorkspace?.focusedPanelId
        let targetPanelExists: Bool
        switch target.host {
        case .workspace(let workspaceId):
            guard let workspace = tabManager.tabs.first(where: {
                $0.id == workspaceId
            }) else {
                commandPaletteFocusRestoreCoordinator.clear()
                return
            }
            targetPanelExists = workspace.panels[target.panelId] != nil
        case .workspaceDock, .windowDock:
            guard let dock = AppDelegate.shared?.dock(
                resolving: BrowserActionTarget(
                    host: target.host,
                    panelId: target.panelId
                )
            ) else {
                commandPaletteFocusRestoreCoordinator.clear()
                return
            }
            targetPanelExists = dock.isVisibleInUI
                && dock.panels[target.panelId] != nil
        }
        guard !commandPaletteFocusRestoreCoordinator.clearIfTargetNoLongerMatchesCurrentFocus(
            currentHost: currentHost,
            focusedPanelId: focusedPanelId,
            targetPanelExists: targetPanelExists
        ) else { return }
        guard commandPaletteFocusRestoreCoordinator.claimRestoreAttempt() else { return }
        defer { commandPaletteFocusRestoreCoordinator.finishRestoreAttempt() }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        let panel: (any Panel)?
        switch target.host {
        case .workspace(let workspaceId):
            tabManager.focusTab(
                workspaceId,
                surfaceId: target.panelId,
                suppressFlash: true,
                dismissRestoredUnreadOnResume: true,
                focusTransactionId: focusTransactionId ?? UUID()
            )
            panel = tabManager.tabs.first(where: { $0.id == workspaceId })?
                .panels[target.panelId]
        case .workspaceDock, .windowDock:
            let dock = AppDelegate.shared?.dock(
                resolving: BrowserActionTarget(
                    host: target.host,
                    panelId: target.panelId
                )
            )
            dock?.focusPanelFromDockInteraction(
                target.panelId,
                window: observedWindow
            )
            panel = dock?.panels[target.panelId]
        }
        guard panel?.restoreFocusIntent(target.intent) == true else { return }
        commandPaletteFocusRestoreCoordinator.clear()
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
            focusedWorkspaceId: workspace.id,
            focusedWorkspaceName: workspaceDisplayName(workspace),
            groupAnchors: tabManager.workspaceGroups.map { group in
                CommandPaletteWorkspaceGroupAnchor(
                    groupId: group.id,
                    anchorWorkspaceId: group.anchorWorkspaceId,
                    name: group.name
                )
            }
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
        if let browserTarget = commandPaletteBrowserActionTarget,
           let dock = AppDelegate.shared?.dock(
               resolving: browserTarget
           ) {
            guard let tabId = dock.surfaceId(
                forPanelId: browserTarget.panelId
            ), let tab = dock.bonsplitController.tab(tabId) else {
                NSSound.beep()
                return
            }
            startRenameFlow(
                CommandPaletteRenameTarget(
                    kind: .tab(
                        workspaceId: dock.workspaceId,
                        panelId: browserTarget.panelId
                    ),
                    currentName: tab.title
                )
            )
            return
        }
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
            if let browserTarget = commandPaletteBrowserActionTarget,
               browserTarget.panelId == panelId,
               let dock = AppDelegate.shared?.dock(
                   resolving: browserTarget
               ), dock.setDockPanelCustomTitle(
                   panelId: panelId,
                   title: normalizedName
               ) {
                break
            } else if let workspace = tabManager.tabs.first(where: {
                $0.id == workspaceId
            }) {
                workspace.setPanelCustomTitle(
                    panelId: panelId,
                    title: normalizedName
                )
            } else {
                NSSound.beep()
                return
            }
        case .workspaceGroup(let groupId):
            // A group must keep a name: an empty field is rejected in place so
            // the user can correct it, unlike workspace/tab renames where empty
            // clears the custom title back to the derived one.
            guard let normalizedName else {
                NSSound.beep()
                return
            }
            tabManager.renameWorkspaceGroup(groupId: groupId, name: normalizedName)
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
            if let focusedPanelId = workspace.focusedPanelId {
                guard workspace.allowsLocalDirectoryFallback(panelId: focusedPanelId) else { return "" }
                if let directory = workspace.reportedPanelDirectory(panelId: focusedPanelId) {
                    return directory
                }
                if let requestedDirectory = workspace.terminalPanel(for: focusedPanelId)?.requestedWorkingDirectory {
                    return requestedDirectory
                }
            }
            guard !workspace.isRemoteWorkspace else { return "" }
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
