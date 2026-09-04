import AppKit
import CmuxTerminal
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

    func setURL(_ url: String?) {
        let url = url?.isEmpty == false ? url : nil
        label.stringValue = url ?? ""
        label.setAccessibilityLabel(url)
        isHidden = url == nil
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
