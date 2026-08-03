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
    private enum Presentation {
        case visible
        case parked(WorkspaceFloatingDockParkingSnapshot)
        case revealed(WorkspaceFloatingDockParkingSnapshot)
    }

    private enum ParkingDragState {
        case inactive
        case armed(startScreenPoint: NSPoint, initialPanelFrame: CGRect)
        case moving(startScreenPoint: NSPoint, initialPanelFrame: CGRect)
    }

    let dock: WorkspaceFloatingDock
    private weak var parentWindow: NSWindow?
    private let onCloseRequest: (UUID) -> Void
    private let onStashRequest: (UUID) -> Void
    private let onRestoreRequest: (UUID) -> Void
    private let onBecomeKey: (UUID) -> Void
    private let onRenameRequest: (UUID, String) -> Bool
    private let glassEffect = WindowGlassEffect()
    private let stashOverlay = WorkspaceFloatingDockStashOverlayView()
    private weak var compatibilityBlurView: NSVisualEffectView?
    private var isApplyingModelFrame = false
    private var isAnimatingPresentation = false
    private var presentationGeneration = 0
    private var hasAppliedInitialScreenPlacement = false
    private var isScreenConfigurationChanging = false
    private var presentation: Presentation = .visible
    private var presentationTargetFrame: CGRect?
    private var parkingDragState: ParkingDragState = .inactive
    private var accessoryIsTransientForVisibleRename = false
    private weak var renameFocusController: MainWindowFocusController?
    private var renameFocusSessionID: UUID?
    private lazy var parkingAccessoryController = WorkspaceFloatingDockParkingAccessoryController(
        dockID: dock.id,
        onRestore: { [weak self] in
            guard let self else { return }
            self.onRestoreRequest(self.dock.id)
        },
        onRename: { [weak self] title in
            guard let self else { return false }
            let renamed = self.onRenameRequest(self.dock.id, title)
            if renamed {
                self.window?.title = self.dock.title
            }
            return renamed
        },
        onDrag: { [weak self] phase, screenPoint in
            self?.handleParkingAccessoryDrag(phase: phase, screenPoint: screenPoint)
        },
        onEditingEnded: { [weak self] in
            self?.parkingAccessoryEditingEnded()
        }
    )

    private var parkingSnapshot: WorkspaceFloatingDockParkingSnapshot? {
        switch presentation {
        case .visible:
            nil
        case .parked(let snapshot), .revealed(let snapshot):
            snapshot
        }
    }

    init(
        dock: WorkspaceFloatingDock,
        parentWindow: NSWindow,
        onCloseRequest: @escaping (UUID) -> Void,
        onStashRequest: @escaping (UUID) -> Void = { _ in },
        onRestoreRequest: @escaping (UUID) -> Void = { _ in },
        onBecomeKey: @escaping (UUID) -> Void = { _ in },
        onRenameRequest: @escaping (UUID, String) -> Bool = { _, _ in false }
    ) {
        self.dock = dock
        self.parentWindow = parentWindow
        self.onCloseRequest = onCloseRequest
        self.onStashRequest = onStashRequest
        self.onRestoreRequest = onRestoreRequest
        self.onBecomeKey = onBecomeKey
        self.onRenameRequest = onRenameRequest

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
        if case .moving = parkingDragState {
            prepareVisiblePanelForParkingDrag(panel)
            return
        }
        if parkingSnapshot != nil {
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
        presentationTargetFrame = panel.frame
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
        if parkingAccessoryController.isVisible {
            parkingAccessoryController.update(
                title: dock.title,
                attachedTo: panel,
                parkingEdge: parkingSnapshot?.edge ?? .trailing,
                appearance: appearance,
                animated: false
            )
        }
    }

    func hide() {
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        parkingDragState = .inactive
        presentation = .visible
        presentationTargetFrame = nil
        stashOverlay.isHidden = true
        if let panel = window as? WorkspaceFloatingDockPanel {
            panel.presentsStashedWindow = false
            panel.level = .normal
        }
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        hideParkingAccessory(animated: false)
        window?.ignoresMouseEvents = false
        window?.orderOut(nil)
    }

    /// Temporarily removes the panel when another cmux window context or app
    /// owns the key window without changing its visible/parked model state.
    func hideForInactiveKeyContext() {
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        parkingDragState = .inactive
        if let parkingSnapshot {
            presentation = .parked(parkingSnapshot)
            presentationTargetFrame = parkingSnapshot.parkedFrame
            setPanelFrame(parkingSnapshot.parkedFrame, display: false)
        }
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        hideParkingAccessory(animated: false)
        window?.ignoresMouseEvents = false
        window?.orderOut(nil)
    }

    func parkingRequest(
        fallbackVisibleScreenFrame: CGRect?,
        migratingToVisibleScreenFrame targetVisibleScreenFrame: CGRect? = nil,
        availableScreenFrames: [CGRect] = []
    ) -> (restoreFrame: CGRect, visibleScreenFrame: CGRect)? {
        guard let panel = window,
              let fallbackVisibleScreenFrame else { return nil }
        if !hasAppliedInitialScreenPlacement {
            applyInitialScreenPlacement()
            hasAppliedInitialScreenPlacement = true
        }
        if let parkingSnapshot {
            if let targetVisibleScreenFrame,
               parkingSnapshot.visibleScreenFrame != targetVisibleScreenFrame {
                let migrated = parkingSnapshot.migrated(
                    toVisibleScreenFrame: targetVisibleScreenFrame,
                    availableScreenFrames: availableScreenFrames
                )
                return (
                    restoreFrame: migrated.restoreFrame,
                    visibleScreenFrame: migrated.visibleScreenFrame
                )
            }
            return (
                restoreFrame: parkingSnapshot.restoreFrame,
                visibleScreenFrame: parkingSnapshot.visibleScreenFrame
            )
        }
        return (
            restoreFrame: panel.frame,
            visibleScreenFrame: panel.screen?.visibleFrame ?? fallbackVisibleScreenFrame
        )
    }

    func showStashed(
        snapshot: WorkspaceFloatingDockParkingSnapshot,
        animated: Bool
    ) {
        guard let panel = window else { return }
        parkingDragState = .inactive
        // A screen migration or stack relayout supersedes any hover/stash
        // animation already targeting this panel. Its completion must not put
        // the window back on the previous display or in an older stack slot.
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        panel.title = dock.title
        let wasKeyWindow = panel.isKeyWindow
        let targetFrame: CGRect
        switch presentation {
        case .visible, .parked:
            presentation = .parked(snapshot)
            targetFrame = snapshot.parkedFrame
        case .revealed:
            presentation = .revealed(snapshot)
            targetFrame = snapshot.revealedFrame
        }
        presentationTargetFrame = targetFrame
#if DEBUG
        cmuxDebugLog(
            "floating.parking.apply dock=\(dock.id.uuidString.prefix(5)) " +
            "generation=\(presentationGeneration) target=\(NSStringFromRect(targetFrame)) " +
            "animated=\(animated ? 1 : 0)"
        )
#endif
        persistRestorableFrame(snapshot.restoreFrame)
        detachParkedPanel(panel)
        stashOverlay.isHidden = false
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(true)
        panel.ignoresMouseEvents = false
        panel.orderFront(nil)
        if case .revealed = presentation {
            showParkingAccessory(
                panel: panel,
                snapshot: snapshot,
                animated: animated
            )
        } else {
            hideParkingAccessory(animated: false)
        }

        guard animated,
              panel.frame != targetFrame,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setPanelFrame(targetFrame, display: panel.isVisible)
            if wasKeyWindow {
                parentWindow?.makeKeyAndOrderFront(nil)
            }
            return
        }
        animatePanel(panel, to: targetFrame, duration: 0.22)
    }

    func stash(
        snapshot: WorkspaceFloatingDockParkingSnapshot,
        completion: @escaping () -> Void
    ) {
        guard let panel = window, panel.isVisible else {
            hide()
            completion()
            return
        }
        parkingDragState = .inactive
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let originalFrame = panel.frame
        let wasKeyWindow = panel.isKeyWindow
        persistRestorableFrame(originalFrame)
        presentation = .parked(snapshot)
        presentationTargetFrame = snapshot.parkedFrame
        hideParkingAccessory(animated: false)
        detachParkedPanel(panel)
        stashOverlay.isHidden = false
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(true)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completeStash(
                panel: panel,
                stashedFrame: snapshot.parkedFrame,
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
            panel.animator().setFrame(snapshot.parkedFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard self.presentationGeneration == generation else {
                self.settleLatestPresentationTarget(on: panel)
                return
            }
            if self.dock.isStashed {
                self.completeStash(
                    panel: panel,
                    stashedFrame: snapshot.parkedFrame,
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
        guard let parkingSnapshot else {
            finishShowing(panel, focus: focus)
            return
        }
        let generation = presentationGeneration
        let destinationFrame = parkingSnapshot.restoreFrame
        presentation = .visible
        presentationTargetFrame = destinationFrame
        accessoryIsTransientForVisibleRename = false
        hideParkingAccessory(animated: true)
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
            guard let self, let panel else { return }
            guard self.presentationGeneration == generation else {
                self.settleLatestPresentationTarget(on: panel)
                return
            }
            guard !self.dock.isStashed else { return }
            self.isAnimatingPresentation = false
            panel.ignoresMouseEvents = false
            self.setPanelFrame(destinationFrame, display: true)
            self.finishShowing(panel, focus: focus)
        }
    }

    func setParkingRevealed(_ isRevealed: Bool, animated: Bool = true) {
        guard dock.isStashed,
              let panel = window,
              let parkingSnapshot else { return }
        let isCurrentlyRevealed: Bool
        switch presentation {
        case .visible, .parked:
            isCurrentlyRevealed = false
        case .revealed:
            isCurrentlyRevealed = true
        }
        guard isRevealed != isCurrentlyRevealed else { return }
        presentation = isRevealed
            ? .revealed(parkingSnapshot)
            : .parked(parkingSnapshot)
        let targetFrame = isRevealed
            ? parkingSnapshot.revealedFrame
            : parkingSnapshot.parkedFrame
        presentationTargetFrame = targetFrame
        if isRevealed {
            showParkingAccessory(
                panel: panel,
                snapshot: parkingSnapshot,
                animated: animated
            )
        } else {
            hideParkingAccessory(animated: animated)
        }
        if animated {
            animatePanel(panel, to: targetFrame, duration: 0.16)
        } else {
            setPanelFrame(targetFrame, display: panel.isVisible)
        }
    }

    func containsParkingRestingPoint(_ screenPoint: NSPoint) -> Bool {
        parkingSnapshot?.containsRestingPoint(screenPoint) == true
    }

    func containsParkingRevealedPoint(_ screenPoint: NSPoint) -> Bool {
        parkingSnapshot?.containsRevealedPoint(screenPoint) == true
            || parkingAccessoryController.contains(screenPoint)
            || parkingAccessoryController.isEditing
            || parkingAccessoryController.isDragging
    }

    func orderStashedWindowFront() {
        guard dock.isStashed, let panel = window else { return }
        panel.orderFront(nil)
    }

    private func handleParkingAccessoryDrag(
        phase: WorkspaceFloatingDockParkingDragPhase,
        screenPoint: NSPoint
    ) {
        guard let panel = window else {
            parkingDragState = .inactive
            return
        }

        switch phase {
        case .began:
            guard dock.isStashed, parkingSnapshot != nil else {
                parkingDragState = .inactive
                return
            }
            parkingDragState = .armed(
                startScreenPoint: screenPoint,
                initialPanelFrame: panel.frame
            )
        case .changed:
            switch parkingDragState {
            case .inactive:
                return
            case .armed(let startScreenPoint, let initialPanelFrame):
                let deltaX = screenPoint.x - startScreenPoint.x
                let deltaY = screenPoint.y - startScreenPoint.y
                guard hypot(deltaX, deltaY) >= WorkspaceFloatingDockParkingGesture.dragThreshold else {
                    return
                }
                parkingDragState = .moving(
                    startScreenPoint: startScreenPoint,
                    initialPanelFrame: initialPanelFrame
                )
                guard beginMovingParkedPanel(panel) else { return }
                moveParkedPanel(
                    panel,
                    from: initialPanelFrame,
                    startScreenPoint: startScreenPoint,
                    currentScreenPoint: screenPoint
                )
            case .moving(let startScreenPoint, let initialPanelFrame):
                moveParkedPanel(
                    panel,
                    from: initialPanelFrame,
                    startScreenPoint: startScreenPoint,
                    currentScreenPoint: screenPoint
                )
            }
        case .ended:
            switch parkingDragState {
            case .inactive:
                return
            case .armed:
                parkingDragState = .inactive
                onRestoreRequest(dock.id)
            case .moving:
                finishMovingParkedPanel(panel)
            }
        case .cancelled:
            parkingDragState = .inactive
        }
    }

    private func beginMovingParkedPanel(_ panel: NSWindow) -> Bool {
        guard let snapshot = parkingSnapshot else { return false }
        presentationGeneration &+= 1
        isAnimatingPresentation = false
        presentation = .visible
        presentationTargetFrame = panel.frame
        prepareVisiblePanelForParkingDrag(panel)

        // Use the same model mutation as the CLI, palette, restore button, and
        // parked-window click. `show(focus:)` recognizes the active drag and
        // leaves geometry under this controller's ownership until mouse-up.
        onRestoreRequest(dock.id)
        guard !dock.isStashed else {
            showStashed(snapshot: snapshot, animated: false)
            return false
        }
        return true
    }

    private func prepareVisiblePanelForParkingDrag(_ panel: NSWindow) {
        presentation = .visible
        presentationTargetFrame = panel.frame
        accessoryIsTransientForVisibleRename = false
        stashOverlay.isHidden = true
        panel.ignoresMouseEvents = false
        if let floatingPanel = panel as? WorkspaceFloatingDockPanel {
            floatingPanel.presentsStashedWindow = false
        }
        if let parentWindow {
            attachVisiblePanel(panel, to: parentWindow)
        }
        dock.store.setVisibleInUI(true)
        panel.orderFront(nil)
    }

    private func moveParkedPanel(
        _ panel: NSWindow,
        from initialPanelFrame: CGRect,
        startScreenPoint: NSPoint,
        currentScreenPoint: NSPoint
    ) {
        var targetFrame = initialPanelFrame
        targetFrame.origin.x += currentScreenPoint.x - startScreenPoint.x
        targetFrame.origin.y += currentScreenPoint.y - startScreenPoint.y
        presentationTargetFrame = targetFrame
        setPanelFrame(targetFrame, display: true)
    }

    private func finishMovingParkedPanel(_ panel: NSWindow) {
        parkingDragState = .inactive
        let targetFrame: CGRect
        if let screen = Self.screen(containing: panel.frame) ?? panel.screen {
            targetFrame = panel.constrainFrameRect(panel.frame, to: screen)
        } else {
            targetFrame = panel.frame
        }
        presentationTargetFrame = targetFrame
        setPanelFrame(targetFrame, display: true)
        persistRestorableFrame(targetFrame)
        hideParkingAccessory(animated: false)
        finishShowing(panel, focus: true)
    }

    private func animatePanel(_ panel: NSWindow, to frame: CGRect, duration: TimeInterval) {
        presentationTargetFrame = frame
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
            guard let self, let panel else { return }
            guard self.presentationGeneration == generation else {
                self.settleLatestPresentationTarget(on: panel)
                return
            }
            guard self.dock.isStashed else { return }
            self.isAnimatingPresentation = false
            self.setPanelFrame(frame, display: true)
        }
    }

    private func settleLatestPresentationTarget(on panel: NSWindow) {
        guard let presentationTargetFrame else { return }
#if DEBUG
        cmuxDebugLog(
            "floating.parking.settle dock=\(dock.id.uuidString.prefix(5)) " +
            "generation=\(presentationGeneration) target=\(NSStringFromRect(presentationTargetFrame))"
        )
#endif
        isAnimatingPresentation = false
        setPanelFrame(presentationTargetFrame, display: panel.isVisible)
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
        parkingDragState = .inactive
        presentationTargetFrame = nil
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        endRenameFocusSession()
        parkingAccessoryController.teardown()
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
        parkingDragState = .inactive
        hideParkingAccessory(animated: false)
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
        if dock.isStashed, parkingSnapshot != nil {
            guard let visibleScreenFrame = Self.visibleScreenFrame(
                containing: resolvedFrame
            ) ?? parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return false
            }
            let snapshot = WorkspaceFloatingDockParkingSnapshot(
                restoreFrame: resolvedFrame,
                visibleScreenFrame: visibleScreenFrame,
                availableScreenFrames: displays.available.map(\.frame)
            )
            presentation = .parked(snapshot)
            setPanelFrame(snapshot.parkedFrame, display: panel.isVisible)
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

    func owns(window candidate: NSWindow) -> Bool {
        window === candidate || parkingAccessoryController.window === candidate
    }

    func beginRenaming() {
        guard let panel = window else { return }
        beginRenameFocusSession()
        if let parkingSnapshot {
            presentation = .revealed(parkingSnapshot)
            accessoryIsTransientForVisibleRename = false
            showParkingAccessory(
                panel: panel,
                snapshot: parkingSnapshot,
                animated: true
            )
            animatePanel(panel, to: parkingSnapshot.revealedFrame, duration: 0.16)
        } else {
            accessoryIsTransientForVisibleRename = true
            parkingAccessoryController.show(
                attachedTo: panel,
                title: dock.title,
                parkingEdge: .trailing,
                appearance: resolvedBackdropAppearance(),
                animated: true
            )
        }
        parkingAccessoryController.beginRenaming()
    }

    private func parkingAccessoryEditingEnded() {
        endRenameFocusSession()
        if accessoryIsTransientForVisibleRename {
            accessoryIsTransientForVisibleRename = false
            hideParkingAccessory(animated: true)
            window?.makeKeyAndOrderFront(nil)
        } else if let panel = window, let parkingSnapshot {
            showParkingAccessory(
                panel: panel,
                snapshot: parkingSnapshot,
                animated: true
            )
            parentWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func beginRenameFocusSession() {
        guard renameFocusSessionID == nil,
              let parentWindow,
              let controller = AppDelegate.shared?.keyboardFocusCoordinator(for: parentWindow) else {
            return
        }
        renameFocusController = controller
        renameFocusSessionID = controller.beginOwnedTransientInputSession()
    }

    private func endRenameFocusSession() {
        guard let id = renameFocusSessionID else { return }
        renameFocusController?.endOwnedTransientInputSession(id)
        renameFocusSessionID = nil
        renameFocusController = nil
    }

    private func hideParkingAccessory(animated: Bool) {
        endRenameFocusSession()
        parkingAccessoryController.hide(animated: animated)
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
        guard let appDelegate = AppDelegate.shared else { return }
        let displaySnapshot: SessionDisplaySnapshot?
        if let screen = Self.screen(containing: frame) {
            displaySnapshot = appDelegate.displaySnapshot(for: screen)
        } else {
            displaySnapshot = appDelegate.displaySnapshot(for: window)
        }
        dock.recordScreenPlacement(
            frame,
            relativeTo: parentWindow.frame,
            displaySnapshot: displaySnapshot,
            configurationSignature: appDelegate.currentDisplayConfigurationSignature()
        )
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

    private func showParkingAccessory(
        panel: NSWindow,
        snapshot: WorkspaceFloatingDockParkingSnapshot,
        animated: Bool
    ) {
        parkingAccessoryController.show(
            attachedTo: panel,
            title: dock.title,
            parkingEdge: snapshot.edge,
            appearance: resolvedBackdropAppearance(),
            animated: animated
        )
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

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Parking intentionally leaves only a narrow slice on-screen. AppKit's
        // generic constrain pass treats that as a stranded titled window and
        // moves every parked panel toward the same reachable titlebar origin.
        // The presenter owns display migration for parked panels, so preserve
        // its exact stack frame until the panel is restored.
        guard !presentsStashedWindow else { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
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
    var onPress: (() -> Void)?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
