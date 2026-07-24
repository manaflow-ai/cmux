import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Observation
import QuartzCore
import SwiftUI

let cmuxWorkspaceFloatingDockWindowIdentifierPrefix = "cmux.workspace.float."

/// One window-root appearance for every floating Dock surface. Bonsplit,
/// terminals, browsers, and note editors stay clear above this substrate.
struct WorkspaceFloatingDockBackdropAppearance {
    let liquidGlassStyle: WindowGlassEffectStyle?
    let tintColor: NSColor?
    let compatibilityMaterial: NSVisualEffectView.Material?
    let opacity: CGFloat

    static let raycastOpacity: CGFloat = 0.96

    static func raycast(backgroundColor: NSColor) -> Self {
        let background = backgroundColor.usingColorSpace(.sRGB)
            ?? NSColor(calibratedWhite: backgroundColor.isLightColor ? 0.94 : 0.12, alpha: 1)
        let neutralWhite: CGFloat = background.isLightColor ? 0.94 : 0.12
        let themeWeight: CGFloat = 0.72
        let neutralWeight = 1 - themeWeight
        let tint = NSColor(
            srgbRed: background.redComponent * themeWeight + neutralWhite * neutralWeight,
            green: background.greenComponent * themeWeight + neutralWhite * neutralWeight,
            blue: background.blueComponent * themeWeight + neutralWhite * neutralWeight,
            alpha: 0.78
        )
        return Self(
            liquidGlassStyle: .regular,
            tintColor: tint,
            compatibilityMaterial: nil,
            opacity: raycastOpacity
        )
    }

    func overriding(tintColor: NSColor?, opacity: CGFloat) -> Self {
        Self(
            liquidGlassStyle: liquidGlassStyle,
            tintColor: tintColor ?? self.tintColor,
            compatibilityMaterial: compatibilityMaterial,
            opacity: opacity
        )
    }
}

/// Owns the native child panel for one workspace floating Dock.
@MainActor
final class WorkspaceFloatingDockWindowController: NSWindowController, NSWindowDelegate {
    private struct StashedPresentation {
        var restoreFrame: CGRect
        var visibleScreenFrame: CGRect
        var isHovered: Bool
    }

    private enum Presentation {
        case visible
        case stashed(StashedPresentation)
    }

    let dock: WorkspaceFloatingDock
    private weak var parentWindow: NSWindow?
    private let onCloseRequest: (UUID) -> Void
    private let onStashRequest: (UUID) -> Void
    private let onRestoreRequest: (UUID) -> Void
    private let onBecomeKey: (UUID) -> Void
    private let glassEffect = WindowGlassEffect()
    private let stashOverlay = WorkspaceFloatingDockStashOverlayView()
    private weak var compatibilityBlurView: NSVisualEffectView?
    private var isApplyingModelFrame = false
    private var isAnimatingPresentation = false
    private var presentationGeneration = 0
    private var hasAppliedInitialScreenPlacement = false
    private var isScreenConfigurationChanging = false
    private var presentation: Presentation = .visible

    init(
        dock: WorkspaceFloatingDock,
        parentWindow: NSWindow,
        onCloseRequest: @escaping (UUID) -> Void,
        onStashRequest: @escaping (UUID) -> Void = { _ in },
        onRestoreRequest: @escaping (UUID) -> Void = { _ in },
        onBecomeKey: @escaping (UUID) -> Void = { _ in }
    ) {
        self.dock = dock
        self.parentWindow = parentWindow
        self.onCloseRequest = onCloseRequest
        self.onStashRequest = onStashRequest
        self.onRestoreRequest = onRestoreRequest
        self.onBecomeKey = onBecomeKey

        let panel = WorkspaceFloatingDockPanel(
            contentRect: Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = dock.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        Self.configureStandardWindowButtons(in: panel)
        panel.identifier = NSUserInterfaceItemIdentifier(
            cmuxWorkspaceFloatingDockWindowIdentifierPrefix + dock.id.uuidString
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 220)
        panel.contentMinSize = NSSize(width: 320, height: 220)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Bonsplit's empty tab-bar chrome owns window drags. Keeping the panel
        // immovable prevents tab drags and other content gestures from moving it.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        let hostingView = WorkspaceFloatingDockHostingView(
            rootView: WorkspaceFloatingDockContentView(dock: dock),
            minimumContentSize: NSSize(width: 320, height: 220)
        )
        panel.contentView = hostingView

        super.init(window: panel)
        stashOverlay.translatesAutoresizingMaskIntoConstraints = false
        stashOverlay.isHidden = true
        let stashOverlayHost = hostingView.superview ?? hostingView
        stashOverlayHost.addSubview(stashOverlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stashOverlay.topAnchor.constraint(equalTo: stashOverlayHost.topAnchor),
            stashOverlay.bottomAnchor.constraint(equalTo: stashOverlayHost.bottomAnchor),
            stashOverlay.leadingAnchor.constraint(equalTo: stashOverlayHost.leadingAnchor),
            stashOverlay.trailingAnchor.constraint(equalTo: stashOverlayHost.trailingAnchor),
        ])
        stashOverlay.onHoverChange = { [weak self] isHovering in
            self?.setStashedWindowHovered(isHovering)
        }
        stashOverlay.onPress = { [weak self] in
            guard let self else { return }
            self.onRestoreRequest(self.dock.id)
        }
        panel.onCustomStash = { [weak self] in
            guard let self else { return }
            self.onStashRequest(self.dock.id)
        }
        panel.delegate = self
        panel.lockContentDrivenSizeChanges()
        glassEffect.changesTintWithWindowKeyState = false
        applyGlassTexture()
        Self.configureStandardWindowButtons(in: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(focus: Bool) {
        guard let panel = window, let parentWindow else { return }
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        panel.ignoresMouseEvents = false
        panel.title = dock.title
        applyGlassTexture()
        Self.configureStandardWindowButtons(in: panel)
        if case .stashed = presentation {
            restoreStashedWindow(
                panel,
                focus: focus
            )
            return
        }
        if hasAppliedInitialScreenPlacement {
            applyModelFrameIfNeeded()
        } else {
            applyInitialScreenPlacement()
            hasAppliedInitialScreenPlacement = true
        }
        if !panel.isVisible {
            attachVisiblePanel(panel, to: parentWindow)
            panel.orderFront(nil)
        }
        dock.store.setVisibleInUI(true)
        finishShowing(panel, focus: focus)
    }

    private func finishShowing(_ panel: NSWindow, focus: Bool) {
        if let parentWindow {
            attachVisiblePanel(panel, to: parentWindow)
        }
        if focus {
            panel.makeKeyAndOrderFront(nil)
            raiseAboveSiblingFloatingDocks(panel)
            _ = dock.store.focusFirstControl()
        }
        captureModelFrame()
    }

    func updateTintInPlace() {
        guard let panel = window else { return }
        let appearance = resolvedBackdropAppearance()
        glassEffect.backgroundOpacity = appearance.opacity
        glassEffect.updateTint(to: panel, color: appearance.tintColor)
        compatibilityBlurView?.alphaValue = appearance.opacity
    }

    func hide() {
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        presentation = .visible
        stashOverlay.isHidden = true
        if let panel = window as? WorkspaceFloatingDockPanel {
            panel.presentsStashedWindow = false
            panel.level = .normal
        }
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        window?.ignoresMouseEvents = false
        window?.orderOut(nil)
    }

    func showStashed(
        visibleScreenFrame: CGRect?,
        animated: Bool
    ) {
        guard let panel = window,
              let parentWindow,
              let visibleScreenFrame else {
            hide()
            return
        }
        if !hasAppliedInitialScreenPlacement {
            applyInitialScreenPlacement()
            hasAppliedInitialScreenPlacement = true
        }
        let stashed: StashedPresentation
        switch presentation {
        case .visible:
            let anchorScreen = panel.screen?.visibleFrame ?? visibleScreenFrame
            stashed = StashedPresentation(
                restoreFrame: panel.frame,
                visibleScreenFrame: anchorScreen,
                isHovered: false
            )
            presentation = .stashed(stashed)
        case .stashed(let existing):
            stashed = existing
        }
        detachParkedPanel(panel)
        stashOverlay.isHidden = false
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(true)
        panel.ignoresMouseEvents = false
        panel.orderFront(nil)

        let targetFrame = WorkspaceFloatingDockStashLayout.stashedWindowFrame(
            windowFrame: stashed.restoreFrame,
            visibleScreenFrame: stashed.visibleScreenFrame,
            isHovered: stashed.isHovered
        )
        guard animated,
              panel.frame != targetFrame,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setPanelFrame(targetFrame, display: panel.isVisible)
            return
        }
        animatePanel(panel, to: targetFrame, duration: 0.22)
    }

    func stash(
        visibleScreenFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        guard let panel = window, panel.isVisible else {
            hide()
            completion()
            return
        }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let originalFrame = panel.frame
        let wasKeyWindow = panel.isKeyWindow
        persistRestorableFrame(originalFrame)
        let anchorScreen = panel.screen?.visibleFrame ?? visibleScreenFrame
        let stashed = StashedPresentation(
            restoreFrame: originalFrame,
            visibleScreenFrame: anchorScreen,
            isHovered: false
        )
        let stashedFrame = WorkspaceFloatingDockStashLayout.stashedWindowFrame(
            windowFrame: stashed.restoreFrame,
            visibleScreenFrame: stashed.visibleScreenFrame,
            isHovered: false
        )
        presentation = .stashed(stashed)
        detachParkedPanel(panel)
        stashOverlay.isHidden = false
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(true)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completeStash(
                panel: panel,
                stashedFrame: stashedFrame,
                wasKeyWindow: wasKeyWindow,
                completion: completion
            )
            return
        }

        isAnimatingPresentation = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.4,
                0.0,
                0.8,
                1.0
            )
            panel.animator().setFrame(stashedFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel,
                  self.presentationGeneration == generation else { return }
            if self.dock.isStashed {
                self.completeStash(
                    panel: panel,
                    stashedFrame: stashedFrame,
                    wasKeyWindow: wasKeyWindow,
                    completion: completion
                )
            } else {
                self.isAnimatingPresentation = false
                self.presentation = .visible
                self.stashOverlay.isHidden = true
                if let panel = panel as? WorkspaceFloatingDockPanel {
                    panel.presentsStashedWindow = false
                    panel.level = .normal
                }
                panel.ignoresMouseEvents = false
                self.setPanelFrame(originalFrame, display: true)
                self.finishShowing(panel, focus: true)
            }
        }
    }

    private func completeStash(
        panel: NSWindow,
        stashedFrame: CGRect,
        wasKeyWindow: Bool,
        completion: @escaping () -> Void
    ) {
        setPanelFrame(stashedFrame, display: true)
        panel.ignoresMouseEvents = false
        isAnimatingPresentation = false
        dock.store.setVisibleInUI(true)
        if wasKeyWindow {
            parentWindow?.makeKeyAndOrderFront(nil)
        }
        completion()
    }

    private func restoreStashedWindow(
        _ panel: NSWindow,
        focus: Bool
    ) {
        guard case .stashed(let stashed) = presentation else {
            finishShowing(panel, focus: focus)
            return
        }
        let generation = presentationGeneration
        let destinationFrame = stashed.restoreFrame
        presentation = .visible
        stashOverlay.isHidden = true
        if let panel = panel as? WorkspaceFloatingDockPanel {
            panel.presentsStashedWindow = false
            panel.level = .normal
        }
        dock.store.setVisibleInUI(true)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              panel.frame != destinationFrame else {
            setPanelFrame(destinationFrame, display: true)
            finishShowing(panel, focus: focus)
            return
        }

        isAnimatingPresentation = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.0,
                0.0,
                0.2,
                1.0
            )
            panel.animator().setFrame(destinationFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel,
                  self.presentationGeneration == generation,
                  !self.dock.isStashed else { return }
            self.isAnimatingPresentation = false
            panel.ignoresMouseEvents = false
            self.setPanelFrame(destinationFrame, display: true)
            self.finishShowing(panel, focus: focus)
        }
    }

    private func setStashedWindowHovered(_ isHovered: Bool) {
        guard dock.isStashed,
              let panel = window,
              case .stashed(var stashed) = presentation else { return }
        guard isHovered != stashed.isHovered else { return }
        stashed.isHovered = isHovered
        presentation = .stashed(stashed)
        let targetFrame = WorkspaceFloatingDockStashLayout.stashedWindowFrame(
            windowFrame: stashed.restoreFrame,
            visibleScreenFrame: stashed.visibleScreenFrame,
            isHovered: isHovered
        )
        animatePanel(panel, to: targetFrame, duration: 0.16)
    }

    func updateStashedPointer(at screenPoint: NSPoint) {
        guard dock.isStashed,
              case .stashed = presentation,
              let panel = window else { return }
        setStashedWindowHovered(panel.frame.contains(screenPoint))
    }

    func orderStashedWindowFront() {
        guard dock.isStashed, let panel = window else { return }
        panel.orderFront(nil)
    }

    private func animatePanel(_ panel: NSWindow, to frame: CGRect, duration: TimeInterval) {
        guard panel.frame != frame else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setPanelFrame(frame, display: true)
            return
        }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        isAnimatingPresentation = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.0,
                0.0,
                0.2,
                1.0
            )
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel,
                  self.presentationGeneration == generation,
                  self.dock.isStashed else { return }
            self.isAnimatingPresentation = false
            self.setPanelFrame(frame, display: true)
        }
    }

    /// Uses AppKit's native cascade policy so a new floating window follows
    /// the same offset and visible-screen clamping as a normal macOS window.
    func cascade(relativeTo sourceWindow: NSWindow) {
        guard let panel = window else { return }
        let sourceTopLeft = NSPoint(x: sourceWindow.frame.minX, y: sourceWindow.frame.maxY)
        let nextTopLeft = sourceWindow.cascadeTopLeft(from: sourceTopLeft)
        _ = panel.cascadeTopLeft(from: nextTopLeft)
        captureModelFrame()
    }

    func teardown() {
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
        if let window {
            glassEffect.remove(from: window)
        }
        compatibilityBlurView?.removeFromSuperview()
        window?.orderOut(nil)
        window?.ignoresMouseEvents = false
        window?.delegate = nil
    }

    func beginScreenConfigurationChange() {
        isScreenConfigurationChanging = true
    }

    @discardableResult
    func reconcileScreenConfiguration() -> Bool {
        guard let panel = window,
              let appDelegate = AppDelegate.shared,
              let signature = appDelegate.currentDisplayConfigurationSignature() else {
            return false
        }
        let displays = appDelegate.currentDisplayGeometries()
        guard let resolvedFrame = WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: signature,
            configFrames: dock.configFrames,
            fallbackFrame: dock.screenFrame ?? panel.frame,
            fallbackDisplay: dock.displaySnapshot ?? appDelegate.displaySnapshot(for: panel),
            availableDisplays: displays.available,
            fallbackDisplayGeometry: displays.fallback
        ) else {
            return false
        }

        defer { isScreenConfigurationChanging = false }
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        persistRestorableFrame(resolvedFrame)
        if dock.isStashed, case .stashed = presentation {
            guard let visibleScreenFrame = Self.visibleScreenFrame(
                containing: resolvedFrame
            ) ?? parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return false
            }
            let stashed = StashedPresentation(
                restoreFrame: resolvedFrame,
                visibleScreenFrame: visibleScreenFrame,
                isHovered: false
            )
            presentation = .stashed(stashed)
            let parkedFrame = WorkspaceFloatingDockStashLayout.stashedWindowFrame(
                windowFrame: stashed.restoreFrame,
                visibleScreenFrame: stashed.visibleScreenFrame,
                isHovered: false
            )
            setPanelFrame(parkedFrame, display: panel.isVisible)
        } else {
            applyScreenFrame(resolvedFrame)
        }
#if DEBUG
        cmuxDebugLog(
            "floatingDock.screen.reconcile dock=\(dock.id.uuidString.prefix(8)) " +
                "signature=\(AppDelegate.signatureLogToken(signature)) " +
                "frame={\(appDelegate.nsRectLogDescription(resolvedFrame))}"
        )
#endif
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest(dock.id)
        return false
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }

    func windowDidMove(_ notification: Notification) {
        captureModelFrame()
    }

    func windowDidResize(_ notification: Notification) {
        if let panel = notification.object as? NSWindow {
            Self.configureStandardWindowButtons(in: panel)
        }
        captureModelFrame()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        (notification.object as? WorkspaceFloatingDockPanel)?.beginUserResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        (notification.object as? WorkspaceFloatingDockPanel)?.endUserResize()
        captureModelFrame()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(320, frameSize.width), height: max(220, frameSize.height))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if dock.isStashed {
            dock.ownsInputFocus = false
            parentWindow?.makeKeyAndOrderFront(nil)
            return
        }
        if let panel = notification.object as? NSWindow {
            Self.configureStandardWindowButtons(in: panel)
            raiseAboveSiblingFloatingDocks(panel)
        }
        dock.ownsInputFocus = true
        onBecomeKey(dock.id)
    }

    func windowDidUpdate(_ notification: Notification) {
        if let panel = notification.object as? NSWindow {
            Self.configureStandardWindowButtons(in: panel)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dock.ownsInputFocus = false
    }

    private func applyModelFrame() {
        guard let panel = window, let parentWindow else { return }
        isApplyingModelFrame = true
        if let panel = panel as? WorkspaceFloatingDockPanel {
            panel.setExplicitFrame(
                Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow),
                display: false
            )
        } else {
            panel.setFrame(Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow), display: false)
        }
        isApplyingModelFrame = false
    }

    private func applyInitialScreenPlacement() {
        guard let panel = window,
              let appDelegate = AppDelegate.shared else {
            applyModelFrameIfNeeded()
            return
        }
        let displays = appDelegate.currentDisplayGeometries()
        guard let target = WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: appDelegate.currentDisplayConfigurationSignature(),
            configFrames: dock.configFrames,
            fallbackFrame: dock.screenFrame,
            fallbackDisplay: dock.displaySnapshot,
            availableDisplays: displays.available,
            fallbackDisplayGeometry: displays.fallback
        ) else {
            applyModelFrameIfNeeded()
            return
        }
        applyScreenFrame(target)
        persistRestorableFrame(target)
    }

    private func applyScreenFrame(_ frame: CGRect) {
        guard let panel = window else { return }
        isApplyingModelFrame = true
        if let panel = panel as? WorkspaceFloatingDockPanel {
            panel.setExplicitFrame(frame, display: panel.isVisible)
        } else {
            panel.setFrame(frame, display: panel.isVisible)
        }
        isApplyingModelFrame = false
    }

    private func applyModelFrameIfNeeded() {
        guard let panel = window, let parentWindow else { return }
        let target = Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow)
        guard panel.frame != target else { return }
        applyModelFrame()
    }

    private func captureModelFrame() {
        guard !isApplyingModelFrame,
              !isAnimatingPresentation,
              !dock.isStashed,
              case .visible = presentation,
              !isScreenConfigurationChanging,
              let panel = window else { return }
        persistRestorableFrame(panel.frame)
    }

    private func persistRestorableFrame(_ frame: CGRect) {
        guard let parentWindow else { return }
        dock.frame = CGRect(
            x: frame.minX - parentWindow.frame.minX,
            y: frame.minY - parentWindow.frame.minY,
            width: frame.width,
            height: frame.height
        )
        dock.screenFrame = frame
        guard let appDelegate = AppDelegate.shared else { return }
        if let screen = Self.screen(containing: frame) {
            dock.displaySnapshot = appDelegate.displaySnapshot(for: screen)
        } else {
            dock.displaySnapshot = appDelegate.displaySnapshot(for: window)
        }
        guard let signature = appDelegate.currentDisplayConfigurationSignature() else { return }
        let entry = SessionConfigFrameEntry(
            signature: signature,
            frame: SessionRectSnapshot(frame),
            display: dock.displaySnapshot,
            lastUsedAt: Date().timeIntervalSince1970
        )
        dock.configFrames = dock.configFrames.upserting(entry)
    }

    private func setPanelFrame(_ frame: CGRect, display: Bool) {
        guard let panel = window else { return }
        isApplyingModelFrame = true
        if let floatingPanel = panel as? WorkspaceFloatingDockPanel {
            floatingPanel.setExplicitFrame(frame, display: display)
        } else {
            panel.setFrame(frame, display: display)
        }
        isApplyingModelFrame = false
    }

    private func attachVisiblePanel(_ panel: NSWindow, to parentWindow: NSWindow) {
        if let floatingPanel = panel as? WorkspaceFloatingDockPanel {
            floatingPanel.presentsStashedWindow = false
        }
        panel.level = .normal
        if let currentParent = panel.parent, currentParent !== parentWindow {
            currentParent.removeChildWindow(panel)
        }
        if panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func detachParkedPanel(_ panel: NSWindow) {
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        if let floatingPanel = panel as? WorkspaceFloatingDockPanel {
            floatingPanel.presentsStashedWindow = true
        }
        panel.level = .floating
    }

    private func raiseAboveSiblingFloatingDocks(_ panel: NSWindow) {
        guard let parentWindow else {
            panel.orderFront(nil)
            return
        }

        // AppKit preserves ordering constraints between a parent and its child
        // windows. Reattaching the activated Dock at the top of that child list
        // makes click-to-front deterministic without changing its window level.
        if panel.parent === parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    private func applyGlassTexture() {
        guard let panel = window else { return }
        glassEffect.remove(from: panel)
        compatibilityBlurView?.removeFromSuperview()
        let appearance = resolvedBackdropAppearance()
        applyBackdropAppearance(appearance, to: panel)
    }

    private func resolvedBackdropAppearance() -> WorkspaceFloatingDockBackdropAppearance {
#if DEBUG
        var appearance = WorkspaceFloatingDockTextureDebugSettings.currentAppearance()
#else
        var appearance = WorkspaceFloatingDockBackdropAppearance.raycast(
            backgroundColor: GhosttyBackgroundTheme.currentColor()
        )
#endif
        if let tintHex = dock.backgroundTintHex,
           let tint = NSColor(hex: tintHex) {
            appearance = appearance.overriding(
                tintColor: tint.withAlphaComponent(0.78),
                opacity: appearance.opacity
            )
        }
        return appearance
    }

    private func applyBackdropAppearance(
        _ appearance: WorkspaceFloatingDockBackdropAppearance,
        to panel: NSWindow
    ) {
        glassEffect.backgroundOpacity = appearance.opacity
        if let style = appearance.liquidGlassStyle {
            glassEffect.apply(to: panel, tintColor: appearance.tintColor, style: style)
        } else if let material = appearance.compatibilityMaterial {
            applyCompatibilityBlur(material: material, to: panel, opacity: appearance.opacity)
        }
    }

    private func applyCompatibilityBlur(
        material: NSVisualEffectView.Material,
        to panel: NSWindow,
        opacity: CGFloat
    ) {
        guard let contentView = panel.contentView, let themeFrame = contentView.superview else { return }
        let blurView = NSVisualEffectView(frame: themeFrame.bounds)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.material = material
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.alphaValue = opacity
        themeFrame.addSubview(blurView, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
        ])
        compatibilityBlurView = blurView
    }

    private static func screenFrame(relativeFrame: CGRect, parentWindow: NSWindow) -> CGRect {
        CGRect(
            x: parentWindow.frame.minX + relativeFrame.minX,
            y: parentWindow.frame.minY + relativeFrame.minY,
            width: relativeFrame.width,
            height: relativeFrame.height
        )
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        let match = NSScreen.screens
            .map { ($0, intersectionArea($0.visibleFrame, frame)) }
            .max { $0.1 < $1.1 }
        guard let match, match.1 > 0 else { return nil }
        return match.0
    }

    private static func visibleScreenFrame(containing frame: CGRect) -> CGRect? {
        screen(containing: frame)?.visibleFrame
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func configureStandardWindowButtons(in panel: NSWindow) {
        var configuredButtons: [NSButton] = []
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = panel.standardWindowButton(buttonType) else { continue }
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = buttonType != .zoomButton
            if buttonType == .miniaturizeButton,
               let floatingPanel = panel as? WorkspaceFloatingDockPanel {
                button.target = floatingPanel
                button.action = #selector(WorkspaceFloatingDockPanel.performCustomStash(_:))
            }
            configuredButtons.append(button)
        }

        guard let titlebarContainer = configuredButtons.first?.superview else { return }
        let desiredMidY = titlebarContainer.bounds.maxY
            - WindowChromeMetrics.bonsplitTabBarHeight / 2
        for button in configuredButtons where button.superview === titlebarContainer {
            var frame = button.frame
            frame.origin.y = desiredMidY - frame.height / 2
            button.setFrameOrigin(frame.origin)
        }
    }
}

/// Keeps the floating Dock's dimensions owned by the user and the workspace
/// model. Bonsplit content can relayout inside the panel, but it cannot grow
/// the native window through AppKit fitting-size propagation.
private final class WorkspaceFloatingDockPanel: NSPanel {
    private enum SizeAuthority: Equatable {
        case initializing
        case contentLocked
        case explicitMutation
        case userResize
    }

    private var sizeAuthority = SizeAuthority.initializing
    var onCustomStash: (() -> Void)?
    var presentsStashedWindow = false

    // These panels behave like workspace-owned windows, not passive utility
    // palettes. Becoming main keeps mouse and keyboard routing attached to the
    // frontmost floating window when several cmux windows overlap.
    override var canBecomeKey: Bool { !presentsStashedWindow }
    override var canBecomeMain: Bool { !presentsStashedWindow }

    override func miniaturize(_ sender: Any?) {}

    override func zoom(_ sender: Any?) {}

    @objc func performCustomStash(_ sender: Any?) {
        onCustomStash?()
    }

    func lockContentDrivenSizeChanges() {
        sizeAuthority = .contentLocked
    }

    func setExplicitFrame(_ frame: NSRect, display: Bool) {
        sizeAuthority = .explicitMutation
        setFrame(frame, display: display)
        sizeAuthority = .contentLocked
    }

    func beginUserResize() {
        sizeAuthority = .userResize
    }

    func endUserResize() {
        sizeAuthority = .contentLocked
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var resolvedFrame = frameRect
        if sizeAuthority == .contentLocked, !frame.isEmpty {
            resolvedFrame.size = frame.size
        }
        super.setFrame(resolvedFrame, display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        guard !presentsStashedWindow || sizeAuthority == .explicitMutation else { return }
        super.setFrameOrigin(point)
    }
}

/// Floating Dock controls should work on the first click even when another
/// cmux window is currently key, matching native titlebar control behavior.
private final class WorkspaceFloatingDockHostingView<Content: View>: UserSizedWindowHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class WorkspaceFloatingDockStashOverlayView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }
}

extension NSWindow {
    var usesWorkspaceFloatingDockGlassBackdrop: Bool {
        identifier?.rawValue.hasPrefix(cmuxWorkspaceFloatingDockWindowIdentifierPrefix) == true
    }
}

#if DEBUG
enum WorkspaceFloatingDockTextureDebugStyle: String, CaseIterable, Identifiable {
    case raycast
    case regular
    case clear
    case smoke
    case frosted
    case warm
    case cool
    case underWindow
    case hud
    case sidebar
    case popover
    case menu
    case titlebar
    case contentBackground
    case transparent

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .raycast:
            "debug.floatingDockTexture.raycast"
        case .regular:
            "debug.floatingDockTexture.regular"
        case .clear:
            "debug.floatingDockTexture.clear"
        case .smoke:
            "debug.floatingDockTexture.smoke"
        case .frosted:
            "debug.floatingDockTexture.frosted"
        case .warm:
            "debug.floatingDockTexture.warm"
        case .cool:
            "debug.floatingDockTexture.cool"
        case .underWindow:
            "debug.floatingDockTexture.underWindow"
        case .hud:
            "debug.floatingDockTexture.hud"
        case .sidebar:
            "debug.floatingDockTexture.sidebar"
        case .popover:
            "debug.floatingDockTexture.popover"
        case .menu:
            "debug.floatingDockTexture.menu"
        case .titlebar:
            "debug.floatingDockTexture.titlebar"
        case .contentBackground:
            "debug.floatingDockTexture.contentBackground"
        case .transparent:
            "debug.floatingDockTexture.transparent"
        }
    }

    var liquidGlass: (style: WindowGlassEffectStyle, tint: NSColor?)? {
        switch self {
        case .raycast:
            let appearance = WorkspaceFloatingDockBackdropAppearance.raycast(
                backgroundColor: GhosttyBackgroundTheme.currentColor()
            )
            return (appearance.liquidGlassStyle ?? .regular, appearance.tintColor)
        case .regular:
            return (.regular, nil)
        case .clear:
            return (.clear, nil)
        case .smoke:
            return (.regular, NSColor.black.withAlphaComponent(0.12))
        case .frosted:
            return (.regular, NSColor.white.withAlphaComponent(0.08))
        case .warm:
            return (.regular, NSColor.systemOrange.withAlphaComponent(0.08))
        case .cool:
            return (.regular, NSColor.systemBlue.withAlphaComponent(0.08))
        case .underWindow, .hud, .sidebar, .popover, .menu, .titlebar, .contentBackground, .transparent:
            return nil
        }
    }

    var compatibilityMaterial: NSVisualEffectView.Material? {
        switch self {
        case .underWindow:
            .underWindowBackground
        case .hud:
            .hudWindow
        case .sidebar:
            .sidebar
        case .popover:
            .popover
        case .menu:
            .menu
        case .titlebar:
            .titlebar
        case .contentBackground:
            .contentBackground
        case .raycast, .regular, .clear, .smoke, .frosted, .warm, .cool, .transparent:
            nil
        }
    }
}

enum WorkspaceFloatingDockTextureDebugSettings {
    static let styleKey = "debugWorkspaceFloatingDockTextureStyle"
    static let tintRedKey = "debugWorkspaceFloatingDockTintRed"
    static let tintGreenKey = "debugWorkspaceFloatingDockTintGreen"
    static let tintBlueKey = "debugWorkspaceFloatingDockTintBlue"
    static let tintStrengthKey = "debugWorkspaceFloatingDockTintStrength"
    static let backdropOpacityKey = "debugWorkspaceFloatingDockBackdropOpacity"
    static let defaultStyle = WorkspaceFloatingDockTextureDebugStyle.raycast
    static let defaultTintRed = 0.5
    static let defaultTintGreen = 0.5
    static let defaultTintBlue = 0.5
    static let defaultTintStrength = 0.0
    static let defaultBackdropOpacity = Double(WorkspaceFloatingDockBackdropAppearance.raycastOpacity)

    static func currentStyle(defaults: UserDefaults = .standard) -> WorkspaceFloatingDockTextureDebugStyle {
        WorkspaceFloatingDockTextureDebugStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? defaultStyle
    }

    static func currentTintColor(defaults: UserDefaults = .standard) -> NSColor? {
        let strength = value(forKey: tintStrengthKey, defaultValue: defaultTintStrength, defaults: defaults)
        guard strength > 0.001 else { return nil }
        return NSColor(
            calibratedRed: value(forKey: tintRedKey, defaultValue: defaultTintRed, defaults: defaults),
            green: value(forKey: tintGreenKey, defaultValue: defaultTintGreen, defaults: defaults),
            blue: value(forKey: tintBlueKey, defaultValue: defaultTintBlue, defaults: defaults),
            alpha: min(max(strength, 0), 1)
        )
    }

    static func currentBackdropOpacity(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(min(max(
            value(forKey: backdropOpacityKey, defaultValue: defaultBackdropOpacity, defaults: defaults),
            0.15
        ), 1))
    }

    static func currentAppearance(defaults: UserDefaults = .standard) -> WorkspaceFloatingDockBackdropAppearance {
        let style = currentStyle(defaults: defaults)
        let opacity = currentBackdropOpacity(defaults: defaults)
        if let liquidGlass = style.liquidGlass {
            return WorkspaceFloatingDockBackdropAppearance(
                liquidGlassStyle: liquidGlass.style,
                tintColor: liquidGlass.tint,
                compatibilityMaterial: nil,
                opacity: opacity
            ).overriding(
                tintColor: currentTintColor(defaults: defaults),
                opacity: opacity
            )
        }
        return WorkspaceFloatingDockBackdropAppearance(
            liquidGlassStyle: nil,
            tintColor: nil,
            compatibilityMaterial: style.compatibilityMaterial,
            opacity: opacity
        )
    }

    static func value(forKey key: String, defaultValue: Double, defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }
}

@MainActor
@Observable
private final class WorkspaceFloatingDockTextureDebugModel {
    var styleRawValue: String {
        didSet { persistAndRefresh() }
    }
    var tintColor: Color {
        didSet { persistAndRefresh() }
    }
    var tintStrength: Double {
        didSet { persistAndRefresh() }
    }
    var backdropOpacity: Double {
        didSet { persistAndRefresh() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        styleRawValue = WorkspaceFloatingDockTextureDebugSettings.currentStyle(defaults: defaults).rawValue
        tintColor = Color(nsColor: NSColor(
            calibratedRed: WorkspaceFloatingDockTextureDebugSettings.value(
                forKey: WorkspaceFloatingDockTextureDebugSettings.tintRedKey,
                defaultValue: WorkspaceFloatingDockTextureDebugSettings.defaultTintRed,
                defaults: defaults
            ),
            green: WorkspaceFloatingDockTextureDebugSettings.value(
                forKey: WorkspaceFloatingDockTextureDebugSettings.tintGreenKey,
                defaultValue: WorkspaceFloatingDockTextureDebugSettings.defaultTintGreen,
                defaults: defaults
            ),
            blue: WorkspaceFloatingDockTextureDebugSettings.value(
                forKey: WorkspaceFloatingDockTextureDebugSettings.tintBlueKey,
                defaultValue: WorkspaceFloatingDockTextureDebugSettings.defaultTintBlue,
                defaults: defaults
            ),
            alpha: 1
        ))
        tintStrength = WorkspaceFloatingDockTextureDebugSettings.value(
            forKey: WorkspaceFloatingDockTextureDebugSettings.tintStrengthKey,
            defaultValue: WorkspaceFloatingDockTextureDebugSettings.defaultTintStrength,
            defaults: defaults
        )
        backdropOpacity = Double(WorkspaceFloatingDockTextureDebugSettings.currentBackdropOpacity(defaults: defaults))
    }

    func reset() {
        styleRawValue = WorkspaceFloatingDockTextureDebugSettings.defaultStyle.rawValue
        tintColor = Color(nsColor: NSColor(
            calibratedRed: WorkspaceFloatingDockTextureDebugSettings.defaultTintRed,
            green: WorkspaceFloatingDockTextureDebugSettings.defaultTintGreen,
            blue: WorkspaceFloatingDockTextureDebugSettings.defaultTintBlue,
            alpha: 1
        ))
        tintStrength = WorkspaceFloatingDockTextureDebugSettings.defaultTintStrength
        backdropOpacity = WorkspaceFloatingDockTextureDebugSettings.defaultBackdropOpacity
    }

    private func persistAndRefresh() {
        defaults.set(styleRawValue, forKey: WorkspaceFloatingDockTextureDebugSettings.styleKey)
        if let color = NSColor(tintColor).usingColorSpace(.sRGB) {
            defaults.set(color.redComponent, forKey: WorkspaceFloatingDockTextureDebugSettings.tintRedKey)
            defaults.set(color.greenComponent, forKey: WorkspaceFloatingDockTextureDebugSettings.tintGreenKey)
            defaults.set(color.blueComponent, forKey: WorkspaceFloatingDockTextureDebugSettings.tintBlueKey)
        }
        defaults.set(tintStrength, forKey: WorkspaceFloatingDockTextureDebugSettings.tintStrengthKey)
        defaults.set(backdropOpacity, forKey: WorkspaceFloatingDockTextureDebugSettings.backdropOpacityKey)
        AppDelegate.shared?.refreshAllWorkspaceFloatingDocks()
    }
}

final class WorkspaceFloatingDockTextureDebugWindowController: ReleasingWindowController {
    static let shared = WorkspaceFloatingDockTextureDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.floatingDockTexture.title",
            defaultValue: "Floating Dock Texture Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.workspaceFloatingDockTextureDebug")
        window.center()
        window.contentView = NSHostingView(rootView: WorkspaceFloatingDockTextureDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private struct WorkspaceFloatingDockTextureDebugView: View {
    @State private var settings = WorkspaceFloatingDockTextureDebugModel()

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 14) {
            Text("debug.floatingDockTexture.heading")
                .cmuxFont(.headline)

            GroupBox("debug.floatingDockTexture.group") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("debug.floatingDockTexture.picker", selection: $settings.styleRawValue) {
                        ForEach(WorkspaceFloatingDockTextureDebugStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    ColorPicker("debug.floatingDockTexture.tintColor", selection: $settings.tintColor)

                    HStack {
                        Text("debug.floatingDockTexture.tintStrength")
                        Slider(value: $settings.tintStrength, in: 0...0.6)
                        Text(settings.tintStrength, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }

                    HStack {
                        Text("debug.floatingDockTexture.backdropOpacity")
                        Slider(value: $settings.backdropOpacity, in: 0.15...1)
                        Text(settings.backdropOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }

                    Button("debug.floatingDockTexture.reset") {
                        settings.reset()
                    }
                }
                .padding(.top, 2)
            }

            Text("debug.floatingDockTexture.compatibility")
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("debug.floatingDockTexture.liveUpdate")
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
