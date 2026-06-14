import AppKit
import CmuxTerminal
import Foundation
import QuartzCore

enum QuickTerminalSettings {
    static let positionKey = "quickTerminal.position"
    static let primarySizeRatioKey = "quickTerminal.primarySizeRatio"
    static let secondarySizeRatioKey = "quickTerminal.secondarySizeRatio"
    static let autoHideKey = "quickTerminal.autoHide"

    static let defaultPosition: QuickTerminalPosition = .top
    static let defaultPrimarySizeRatio: Double = 0.38
    static let defaultSecondarySizeRatio: Double = 1.0
    static let defaultAutoHide = true
    static let defaultAnimationDuration: TimeInterval = 0.16

    static func resolved(defaults: UserDefaults = .standard) -> QuickTerminalResolvedSettings {
        let rawPosition = defaults.string(forKey: positionKey)
        let position = QuickTerminalPosition(rawValue: rawPosition ?? "") ?? defaultPosition

        let rawPrimary = defaults.double(forKey: primarySizeRatioKey)
        let primarySizeRatio = clampRatio(
            defaults.object(forKey: primarySizeRatioKey) == nil ? defaultPrimarySizeRatio : rawPrimary
        )

        let rawSecondary = defaults.double(forKey: secondarySizeRatioKey)
        let secondarySizeRatio = clampRatio(
            defaults.object(forKey: secondarySizeRatioKey) == nil ? defaultSecondarySizeRatio : rawSecondary
        )

        let autoHide = defaults.object(forKey: autoHideKey) == nil
            ? defaultAutoHide
            : defaults.bool(forKey: autoHideKey)

        return QuickTerminalResolvedSettings(
            position: position,
            primarySizeRatio: primarySizeRatio,
            secondarySizeRatio: secondarySizeRatio,
            autoHide: autoHide,
            animationDuration: defaultAnimationDuration
        )
    }

    static func clampRatio(_ value: Double) -> Double {
        min(max(value, 0.2), 1.0)
    }
}

struct QuickTerminalResolvedSettings {
    let position: QuickTerminalPosition
    let primarySizeRatio: Double
    let secondarySizeRatio: Double
    let autoHide: Bool
    let animationDuration: TimeInterval
}

enum QuickTerminalPosition: String, CaseIterable, Identifiable {
    case top
    case bottom
    case left
    case right
    case center

    var id: String { rawValue }

    func finalFrame(
        in visibleFrame: NSRect,
        primarySizeRatio: Double,
        secondarySizeRatio: Double
    ) -> NSRect {
        let primary = CGFloat(QuickTerminalSettings.clampRatio(primarySizeRatio))
        let secondary = CGFloat(QuickTerminalSettings.clampRatio(secondarySizeRatio))
        let minWidth: CGFloat = 420
        let minHeight: CGFloat = 200

        let size: NSSize = {
            switch self {
            case .top, .bottom:
                return NSSize(
                    width: max(minWidth, visibleFrame.width * secondary),
                    height: max(minHeight, visibleFrame.height * primary)
                )
            case .left, .right:
                return NSSize(
                    width: max(minWidth, visibleFrame.width * primary),
                    height: max(minHeight, visibleFrame.height * secondary)
                )
            case .center:
                return NSSize(
                    width: max(minWidth, visibleFrame.width * primary),
                    height: max(minHeight, visibleFrame.height * secondary)
                )
            }
        }()

        let clamped = NSSize(
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
        )

        switch self {
        case .top:
            return NSRect(
                x: round(visibleFrame.midX - clamped.width / 2),
                y: visibleFrame.maxY - clamped.height,
                width: clamped.width,
                height: clamped.height
            )
        case .bottom:
            return NSRect(
                x: round(visibleFrame.midX - clamped.width / 2),
                y: visibleFrame.minY,
                width: clamped.width,
                height: clamped.height
            )
        case .left:
            return NSRect(
                x: visibleFrame.minX,
                y: round(visibleFrame.midY - clamped.height / 2),
                width: clamped.width,
                height: clamped.height
            )
        case .right:
            return NSRect(
                x: visibleFrame.maxX - clamped.width,
                y: round(visibleFrame.midY - clamped.height / 2),
                width: clamped.width,
                height: clamped.height
            )
        case .center:
            return NSRect(
                x: round(visibleFrame.midX - clamped.width / 2),
                y: round(visibleFrame.midY - clamped.height / 2),
                width: clamped.width,
                height: clamped.height
            )
        }
    }

    func hiddenFrame(from finalFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        switch self {
        case .top:
            return NSRect(
                x: finalFrame.origin.x,
                y: visibleFrame.maxY,
                width: finalFrame.width,
                height: finalFrame.height
            )
        case .bottom:
            return NSRect(
                x: finalFrame.origin.x,
                y: visibleFrame.minY - finalFrame.height,
                width: finalFrame.width,
                height: finalFrame.height
            )
        case .left:
            return NSRect(
                x: visibleFrame.minX - finalFrame.width,
                y: finalFrame.origin.y,
                width: finalFrame.width,
                height: finalFrame.height
            )
        case .right:
            return NSRect(
                x: visibleFrame.maxX,
                y: finalFrame.origin.y,
                width: finalFrame.width,
                height: finalFrame.height
            )
        case .center:
            return NSRect(
                x: finalFrame.origin.x,
                y: visibleFrame.maxY + 18,
                width: finalFrame.width,
                height: finalFrame.height
            )
        }
    }
}

private final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate {
    private enum VisibilityPhase {
        case hidden
        case showing
        case visible
        case hiding

        var reportsVisible: Bool {
            switch self {
            case .showing, .visible:
                return true
            case .hiding, .hidden:
                return false
            }
        }

        var canAutoHide: Bool {
            switch self {
            case .visible:
                return true
            case .showing, .hiding, .hidden:
                return false
            }
        }

        var isTransitioning: Bool {
            switch self {
            case .showing, .hiding:
                return true
            case .visible, .hidden:
                return false
            }
        }
    }

    private enum PendingTransitionAction {
        case show(activateApp: Bool)
        case hide(restorePreviousApp: Bool)
    }

    private var panel: QuickTerminalPanel?
    private var terminalSurface: TerminalSurface?
    private var previousFrontmostApp: NSRunningApplication?
    private let workspaceId = UUID()
    private var portOrdinal: Int?
    private var phase: VisibilityPhase = .hidden
    private var pendingTransitionAction: PendingTransitionAction?

    private var isVisible: Bool { phase.reportsVisible }

    @discardableResult
    func toggle(activateApp: Bool = true) -> Bool {
        if isVisible {
            return hide(restorePreviousApp: activateApp)
        } else {
            return show(activateApp: activateApp)
        }
    }

    @discardableResult
    func show(activateApp: Bool = true) -> Bool {
        if phase.isTransitioning {
            pendingTransitionAction = .show(activateApp: activateApp)
            return true
        }
        guard !isVisible else { return true }

        let settings = QuickTerminalSettings.resolved()
        guard let panel = ensurePanel(),
              let visibleFrame = screen(for: panel)?.visibleFrame else {
            return false
        }
        let finalFrame = settings.position.finalFrame(
            in: visibleFrame,
            primarySizeRatio: settings.primarySizeRatio,
            secondarySizeRatio: settings.secondarySizeRatio
        )
        let hiddenFrame = settings.position.hiddenFrame(from: finalFrame, visibleFrame: visibleFrame)

        if activateApp,
           !NSApp.isActive,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }

        phase = .showing
        panel.alphaValue = 0
        panel.setFrame(hiddenFrame, display: false)
        panel.level = .popUpMenu
        if activateApp {
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }

        terminalSurface?.hostedView.setVisibleInUI(true)
        terminalSurface?.hostedView.setActive(activateApp)

        if activateApp, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = settings.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase = .visible
                panel.level = .floating
                if activateApp {
                    panel.makeKeyAndOrderFront(nil)
                    panel.makeFirstResponder(self.terminalSurface?.hostedView)
                    self.terminalSurface?.hostedView.setActive(true)
                    self.terminalSurface?.hostedView.moveFocus()
                } else {
                    panel.orderFront(nil)
                    self.terminalSurface?.hostedView.setActive(false)
                }
                self.replayPendingTransitionActionIfNeeded()
            }
        }
        return true
    }

    @discardableResult
    func hide(restorePreviousApp: Bool) -> Bool {
        if phase.isTransitioning {
            pendingTransitionAction = .hide(restorePreviousApp: restorePreviousApp)
            return true
        }
        guard isVisible else { return true }

        let settings = QuickTerminalSettings.resolved()
        guard let panel else {
            phase = .hidden
            previousFrontmostApp = nil
            return false
        }

        guard let visibleFrame = screen(for: panel)?.visibleFrame else {
            finishHide(panel: panel, restorePreviousApp: restorePreviousApp)
            return true
        }
        let hiddenFrame = settings.position.hiddenFrame(from: panel.frame, visibleFrame: visibleFrame)

        phase = .hiding

        NSAnimationContext.runAnimationGroup { context in
            context.duration = settings.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(hiddenFrame, display: false)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishHide(panel: panel, restorePreviousApp: restorePreviousApp)
            }
        }
        return true
    }

    func statusPayload() -> [String: Any] {
        let settings = QuickTerminalSettings.resolved()
        return [
            "available": true,
            "visible": isVisible,
            "position": settings.position.rawValue,
            "auto_hide": settings.autoHide,
            "primary_size_ratio": settings.primarySizeRatio,
            "secondary_size_ratio": settings.secondarySizeRatio
        ]
    }

    func teardown() {
        panel?.orderOut(nil)
        terminalSurface?.hostedView.setActive(false)
        terminalSurface?.hostedView.setVisibleInUI(false)
        panel = nil
        terminalSurface = nil
        portOrdinal = nil
        phase = .hidden
        previousFrontmostApp = nil
        pendingTransitionAction = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === self.panel else { return }
        guard panel.attachedSheet == nil else { return }
        guard phase.canAutoHide else { return }

        let settings = QuickTerminalSettings.resolved()
        if settings.autoHide {
            hide(restorePreviousApp: false)
        } else {
            previousFrontmostApp = nil
        }
    }

    private func replayPendingTransitionActionIfNeeded() {
        guard !phase.isTransitioning, let action = pendingTransitionAction else { return }
        pendingTransitionAction = nil
        switch action {
        case .show(let activateApp):
            show(activateApp: activateApp)
        case .hide(let restorePreviousApp):
            hide(restorePreviousApp: restorePreviousApp)
        }
    }

    private func ensurePanel() -> QuickTerminalPanel? {
        if let panel {
            return panel
        }

        let settings = QuickTerminalSettings.resolved()
        guard let visibleFrame = screen(for: nil)?.visibleFrame else {
            return nil
        }
        let initialFrame = settings.position.finalFrame(
            in: visibleFrame,
            primarySizeRatio: settings.primarySizeRatio,
            secondarySizeRatio: settings.secondarySizeRatio
        )
        let panel = QuickTerminalPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.quick-terminal")
        panel.title = String(localized: "quickTerminal.window.title", defaultValue: "Quick Terminal")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        if terminalSurface == nil {
            terminalSurface = TerminalSurface(
                tabId: workspaceId,
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
                configTemplate: nil,
                portOrdinal: quickTerminalPortOrdinal(),
                initialEnvironmentOverrides: ["CMUX_QUICK_TERMINAL": "1"]
            )
        }

        if let terminalSurface {
            terminalSurface.hostedView.frame = NSRect(origin: .zero, size: initialFrame.size)
            terminalSurface.hostedView.autoresizingMask = [.width, .height]
            terminalSurface.hostedView.setVisibleInUI(false)
            terminalSurface.hostedView.setActive(false)
            panel.contentView = terminalSurface.hostedView
        }

        self.panel = panel
        return panel
    }

    private func quickTerminalPortOrdinal() -> Int {
        if let portOrdinal {
            return portOrdinal
        }
        let allocatedOrdinal = TabManager.allocatePortOrdinal()
        portOrdinal = allocatedOrdinal
        return allocatedOrdinal
    }

    private func finishHide(panel: QuickTerminalPanel, restorePreviousApp: Bool) {
        phase = .hidden
        panel.orderOut(nil)
        terminalSurface?.hostedView.setActive(false)
        terminalSurface?.hostedView.setVisibleInUI(false)
        if restorePreviousApp,
           let previousFrontmostApp,
           !previousFrontmostApp.isTerminated {
            _ = previousFrontmostApp.activate(options: [])
        }
        previousFrontmostApp = nil
        replayPendingTransitionActionIfNeeded()
    }

    private func screen(for panel: NSWindow?) -> NSScreen? {
        if let panel, let panelScreen = panel.screen {
            return panelScreen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        if let main = NSScreen.main {
            return main
        }
        if let first = NSScreen.screens.first {
            return first
        }
        return nil
    }
}
