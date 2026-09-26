import AppKit
import CmuxSettings
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class TerminalLinkHoverIndicatorView: NSView {
    private let backdrop = GhosttyPassthroughVisualEffectView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        backdrop.alphaValue = 0.96

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(backdrop)
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// The link currently under the pointer, or `nil` when no link is hovered.
    private(set) var url: String?

    func setURL(_ url: String?) {
        let url = url?.isEmpty == false ? url : nil
        self.url = url
        label.stringValue = url ?? ""
        label.setAccessibilityLabel(url)
        isHidden = url == nil
    }
}

/// Lock badge shown in the terminal's bottom-trailing corner while the
/// foreground program has echo off for a password prompt, optionally with one
/// dot per typed character.
///
/// Drawn in cmux chrome only; nothing is written to the terminal. The view
/// holds a keystroke count through ``TerminalPasswordInputIndicatorState`` and
/// never sees, stores, or logs the typed characters.
final class TerminalPasswordInputIndicatorView: NSView {
    /// Dots beyond this count collapse into a trailing "+" so the badge stays small.
    static let maximumDisplayedDots = 24

    private let backdrop = GhosttyPassthroughVisualEffectView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let dotsLabel = NSTextField(labelWithString: "")
    private(set) var state = TerminalPasswordInputIndicatorState()
    private var showsIndicator = true
    private var showsDots = false

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        backdrop.alphaValue = 0.96

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setAccessibilityElement(false)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.stringValue = String(
            localized: "terminal.passwordInput.indicator",
            defaultValue: "Password input"
        )
        label.setAccessibilityElement(false)

        dotsLabel.translatesAutoresizingMaskIntoConstraints = false
        dotsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        dotsLabel.textColor = .secondaryLabelColor
        dotsLabel.lineBreakMode = .byClipping
        dotsLabel.setAccessibilityElement(false)
        dotsLabel.isHidden = true

        let stack = NSStackView(views: [iconView, label, dotsLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5

        addSubview(backdrop)
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -4),
        ])

        backdrop.setAccessibilityElement(true)
        backdrop.setAccessibilityRole(.staticText)
        backdrop.setAccessibilityLabel(label.stringValue)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// True when a keystroke would change what the badge shows. The key path
    /// checks this before classifying an event, so typing outside a password
    /// prompt pays only this Boolean read.
    var wantsKeystrokes: Bool {
        state.isActive && showsIndicator && showsDots
    }

    /// Applies Ghostty's password-input (echo off) state for this surface.
    func setEchoDisabled(_ echoDisabled: Bool) {
        if echoDisabled {
            let terminal = TerminalCatalogSection()
            showsIndicator = terminal.showPasswordInputIndicator.value(in: .standard)
            showsDots = terminal.showPasswordInputDots.value(in: .standard)
        }
        state.setEchoDisabled(echoDisabled)
        render()
    }

    func record(_ keystroke: TerminalPasswordInputIndicatorState.Keystroke) {
        guard wantsKeystrokes, state.record(keystroke) else { return }
        render()
    }

    private func render() {
        isHidden = !(state.isActive && showsIndicator)
        guard !isHidden else {
            dotsLabel.stringValue = ""
            return
        }
        let count = state.typedCount
        dotsLabel.isHidden = !showsDots || count == 0
        guard !dotsLabel.isHidden else { return }
        let shown = min(count, Self.maximumDisplayedDots)
        dotsLabel.stringValue = String(repeating: "\u{2022}", count: shown)
            + (count > shown ? "+" : "")
    }
}

extension GhosttySurfaceScrollView {
    /// Shows or clears the password input badge; safe from any thread.
    func setPasswordInputActive(_ active: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setPasswordInputActive(active) }
            return
        }
        passwordInputIndicatorView.setEchoDisabled(active)
    }
}

extension GhosttySurfaceScrollView {
    nonisolated static func linkHoverURL(from link: ghostty_action_mouse_over_link_s) -> String? {
        guard link.len > 0, let bytes = link.url else { return nil }
        return String(data: Data(bytes: bytes, count: Int(link.len)), encoding: .utf8)
    }

    func setLinkHoverURL(_ url: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setLinkHoverURL(url) }
            return
        }
        linkHoverIndicatorView.setURL(url)
    }
}

extension GhosttyNSView {
    /// Counts a key press toward the password input dots. Returns after one
    /// Boolean check unless a password prompt is active with dots enabled.
    /// The event is only classified; its characters are never retained.
    func recordPasswordInputKeystrokeIfNeeded(_ event: NSEvent) {
        guard let indicator = terminalSurface?.hostedView.passwordInputIndicatorView,
              indicator.wantsKeystrokes,
              !hasMarkedText() else { return }
        indicator.record(.classify(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            control: event.modifierFlags.contains(.control),
            command: event.modifierFlags.contains(.command)
        ))
    }
}

extension GhosttyNSView {
    /// Keep the terminal cursor out of the native resize rim on full-size main
    /// windows. A cursor rect is not clipped to the window frame, so claiming
    /// the view's full bounds would hide AppKit's edge and corner resize cursors.
    func terminalCursorRect() -> NSRect {
        guard let window,
              window is CmuxMainWindow,
              window.styleMask.contains(.resizable),
              window.styleMask.contains(.fullSizeContentView),
              !window.styleMask.contains(.fullScreen)
        else {
            return bounds
        }

        let rectInWindow = convert(bounds, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        let windowFrame = window.frame
        var claimedRect = rectInScreen.intersection(windowFrame)
        guard !claimedRect.isNull, claimedRect.width > 0, claimedRect.height > 0 else {
            return .zero
        }

        let edgeTolerance: CGFloat = 1
        let nativeResizeBorderWidth: CGFloat = 4
        if abs(claimedRect.minX - windowFrame.minX) <= edgeTolerance {
            claimedRect.origin.x += nativeResizeBorderWidth
            claimedRect.size.width -= nativeResizeBorderWidth
        }
        if abs(claimedRect.maxX - windowFrame.maxX) <= edgeTolerance {
            claimedRect.size.width -= nativeResizeBorderWidth
        }
        if abs(claimedRect.minY - windowFrame.minY) <= edgeTolerance {
            claimedRect.origin.y += nativeResizeBorderWidth
            claimedRect.size.height -= nativeResizeBorderWidth
        }
        if abs(claimedRect.maxY - windowFrame.maxY) <= edgeTolerance {
            claimedRect.size.height -= nativeResizeBorderWidth
        }
        guard claimedRect.width > 0, claimedRect.height > 0 else { return .zero }

        let adjustedRectInWindow = window.convertFromScreen(claimedRect)
        let adjustedRectInView = convert(adjustedRectInWindow, from: nil)
        let clippedRect = adjustedRectInView.intersection(bounds)
        guard !clippedRect.isNull, clippedRect.width > 0, clippedRect.height > 0 else {
            return .zero
        }
        return clippedRect
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

extension TerminalSurface {
    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }

    func debugInitialInputForTesting() -> String? {
        initialInput
    }
}
