public import AppKit
public import SwiftUI
internal import CmuxAppKitSupportUI
internal import CmuxCommandPalette
internal import ObjectiveC
#if DEBUG
internal import CMUXDebugLog
#endif

/// Per-window controller that installs and drives the command-palette overlay
/// inside a window's chrome.
///
/// One controller is created lazily per ``AppKit/NSWindow`` (retained via an
/// associated object, see ``installed(in:)``). It hosts a SwiftUI palette root
/// inside a ``CommandPaletteOverlayContainerView``, installs it above the window
/// content using the ``WindowContentOverlayTargetResolver`` install target, and
/// owns the focus-lock machinery that keeps the palette text input first
/// responder while the palette is visible.
@MainActor
public final class WindowCommandPaletteOverlayController: NSObject {
    private weak var window: NSWindow?
    private let containerView = CommandPaletteOverlayContainerView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let glassEffect = WindowGlassEffect()
    private let contentOverlayTargetResolver: WindowContentOverlayTargetResolver
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var focusLockTimer: (any DispatchSourceTimer)?
    private var scheduledFocusWorkItem: DispatchWorkItem?
    private var isPaletteVisible = false
    private var hasMountedPaletteRootView = false
    private var windowDidBecomeKeyObserver: (any NSObjectProtocol)?
    private var windowDidResignKeyObserver: (any NSObjectProtocol)?

    /// Creates a controller bound to `window` and installs its overlay container.
    public init(window: NSWindow) {
        self.window = window
        self.contentOverlayTargetResolver = WindowContentOverlayTargetResolver(glassEffect: glassEffect)
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
              let target = contentOverlayTargetResolver
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
            logDebugEvent(
                "palette.overlay.install container=\(String(describing: type(of: target.container))) " +
                "reference=\(String(describing: type(of: target.reference))) " +
                "glass=\(glassEffect.portalInstallationTarget(for: window) != nil ? 1 : 0)"
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
            logDebugEvent(
                "palette.focus.direct missingInput window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            return false
        }
#if DEBUG
        logDebugEvent(
            "palette.focus.direct attempt window={\((window).commandPaletteWindowDebugSummary)} " +
            "input=\((input).commandPaletteResponderDebugSummary) " +
            "frBefore=\((window.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
        guard window.makeFirstResponder(input) else {
#if DEBUG
            logDebugEvent(
                "palette.focus.direct failedMakeFirstResponder window={\((window).commandPaletteWindowDebugSummary)} " +
                "input=\((input).commandPaletteResponderDebugSummary) " +
                "frAfter=\((window.firstResponder).commandPaletteResponderDebugSummary)"
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
        logDebugEvent(
            "palette.focus.direct settled window={\((window).commandPaletteWindowDebugSummary)} " +
            "didSettle=\(didSettle ? 1 : 0) frAfter=\((window.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
        return didSettle
    }

    private func scheduleFocusIntoPalette(retries: Int = 4) {
#if DEBUG
        if let window {
            logDebugEvent(
                "palette.focus.schedule retries=\(retries) " +
                "window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
        } else {
            logDebugEvent("palette.focus.schedule retries=\(retries) window=nil")
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
        logDebugEvent(
            "palette.focus.retry start retries=\(retries) " +
            "window={\((window).commandPaletteWindowDebugSummary)} " +
            "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
        if isPaletteTextInputFirstResponder(window.firstResponder) {
#if DEBUG
            logDebugEvent(
                "palette.focus.retry alreadyFocused window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            return
        }

        if focusPaletteTextInput(in: window) {
#if DEBUG
            logDebugEvent(
                "palette.focus.retry directSuccess retries=\(retries) " +
                "window={\((window).commandPaletteWindowDebugSummary)}"
            )
#endif
            return
        }

        let containerFocused = window.makeFirstResponder(containerView)
#if DEBUG
        logDebugEvent(
            "palette.focus.retry containerResult retries=\(retries) " +
            "window={\((window).commandPaletteWindowDebugSummary)} " +
            "didFocusContainer=\(containerFocused ? 1 : 0) " +
            "frAfterContainer=\((window.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
        if containerFocused {
            if focusPaletteTextInput(in: window) {
#if DEBUG
                logDebugEvent(
                    "palette.focus.retry containerAssistedSuccess retries=\(retries) " +
                    "window={\((window).commandPaletteWindowDebugSummary)}"
                )
#endif
                return
            }
        }

        guard retries > 0 else {
#if DEBUG
            logDebugEvent(
                "palette.focus.retry exhausted window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            return
        }
#if DEBUG
        logDebugEvent(
            "palette.focus.retry reschedule nextRetries=\(retries - 1) " +
            "window={\((window).commandPaletteWindowDebugSummary)}"
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
            logDebugEvent(
                "palette.focus.lock inactive visible=0 window={\((window).commandPaletteWindowDebugSummary)}"
            )
#endif
            stopFocusLockTimer()
            return
        }

        guard window.isKeyWindow else {
#if DEBUG
            logDebugEvent(
                "palette.focus.lock keyWindowMissing window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
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
            logDebugEvent(
                "palette.focus.lock requestRestore window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            scheduleFocusIntoPalette(retries: 8)
        }
    }

    private func startFocusLockTimer() {
        guard focusLockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(12))
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
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

    /// Mounts (or unmounts) the palette overlay and drives its focus lock.
    ///
    /// `makeRootView` is evaluated only when becoming visible to build the
    /// SwiftUI palette root.
    public func update(
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
            logDebugEvent(
                "palette.overlay.update visible=\(isVisible ? 1 : 0) promote=\(shouldPromote ? 1 : 0) " +
                "window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
        } else {
            logDebugEvent("palette.overlay.update visible=\(isVisible ? 1 : 0) promote=\(shouldPromote ? 1 : 0) window=nil")
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

    /// Returns the responder underneath the overlay at `windowPoint`, briefly
    /// disabling mouse capture so the hit test reaches the views beneath.
    public func underlyingResponder(atWindowPoint windowPoint: NSPoint) -> NSResponder? {
        guard let window,
              let target = contentOverlayTargetResolver
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

extension WindowCommandPaletteOverlayController {
    /// Associated-object key used to retain one controller per window.
    private static let associationKey = malloc(1)!

    /// Returns the controller already installed in `window`, creating and
    /// retaining one (via an associated object) on first access.
    public static func installed(in window: NSWindow) -> WindowCommandPaletteOverlayController {
        if let existing = objc_getAssociatedObject(window, associationKey) as? WindowCommandPaletteOverlayController {
            return existing
        }
        let controller = WindowCommandPaletteOverlayController(window: window)
        objc_setAssociatedObject(window, associationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
}
