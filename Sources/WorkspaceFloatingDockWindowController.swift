import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Observation
import SwiftUI

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
    let dock: WorkspaceFloatingDock
    private weak var parentWindow: NSWindow?
    private let onCloseRequest: (UUID) -> Void
    private let onMinimizeRequest: (UUID) -> Void
    private let onBecomeKey: (UUID) -> Void
    private let glassEffect = WindowGlassEffect()
    private weak var compatibilityBlurView: NSVisualEffectView?
    private var isApplyingModelFrame = false
    private var hasAppliedInitialScreenPlacement = false
    private var isScreenConfigurationChanging = false

    init(
        dock: WorkspaceFloatingDock,
        parentWindow: NSWindow,
        onCloseRequest: @escaping (UUID) -> Void,
        onMinimizeRequest: @escaping (UUID) -> Void,
        onCreateRequest: @escaping () -> Void,
        onBecomeKey: @escaping (UUID) -> Void = { _ in }
    ) {
        self.dock = dock
        self.parentWindow = parentWindow
        self.onCloseRequest = onCloseRequest
        self.onMinimizeRequest = onMinimizeRequest
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
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.workspace.float.\(dock.id.uuidString)")
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
        // Keep AppKit out of the full-size titlebar's drag decision. Bonsplit
        // owns tab drags; the explicit grid handle temporarily enables native
        // movement only while it calls performDrag.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.contentView = WorkspaceFloatingDockHostingView(
            rootView: WorkspaceFloatingDockContentView(
                dock: dock,
                onCreateDock: onCreateRequest
            ),
            minimumContentSize: NSSize(width: 320, height: 220)
        )

        super.init(window: panel)
        panel.onCustomMinimize = { [weak self] in
            guard let self else { return }
            self.onMinimizeRequest(self.dock.id)
            self.parentWindow?.makeKeyAndOrderFront(nil)
        }
        panel.delegate = self
        panel.lockContentDrivenSizeChanges()
        glassEffect.changesTintWithWindowKeyState = false
        applyGlassTexture()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(focus: Bool) {
        guard let panel = window, let parentWindow else { return }
        panel.title = dock.title
        Self.configureStandardWindowButtons(in: panel)
        applyGlassTexture()
        if hasAppliedInitialScreenPlacement {
            applyModelFrameIfNeeded()
        } else {
            applyInitialScreenPlacement()
            hasAppliedInitialScreenPlacement = true
        }
        if !panel.isVisible {
            if panel.parent !== parentWindow {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        dock.isPresented = true
        dock.store.setVisibleInUI(true)
        if focus {
            if panel.isMiniaturized {
                panel.deminiaturize(nil)
            }
            panel.makeKeyAndOrderFront(nil)
            raiseAboveSiblingFloatingDocks(panel)
            _ = dock.store.focusFirstControl()
        }
        captureModelFrame()
    }

    func hide() {
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        window?.orderOut(nil)
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

        applyScreenFrame(resolvedFrame)
        captureModelFrame(allowDuringScreenConfigurationChange: true)
        isScreenConfigurationChanging = false
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
        captureModelFrame()
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

    private func captureModelFrame(allowDuringScreenConfigurationChange: Bool = false) {
        guard !isApplyingModelFrame,
              allowDuringScreenConfigurationChange || !isScreenConfigurationChanging,
              let panel = window,
              let parentWindow else { return }
        dock.frame = CGRect(
            x: panel.frame.minX - parentWindow.frame.minX,
            y: panel.frame.minY - parentWindow.frame.minY,
            width: panel.frame.width,
            height: panel.frame.height
        )
        dock.screenFrame = panel.frame
        guard let appDelegate = AppDelegate.shared else { return }
        dock.displaySnapshot = appDelegate.displaySnapshot(for: panel)
        guard let signature = appDelegate.currentDisplayConfigurationSignature() else { return }
        let entry = SessionConfigFrameEntry(
            signature: signature,
            frame: SessionRectSnapshot(panel.frame),
            display: dock.displaySnapshot,
            lastUsedAt: Date().timeIntervalSince1970
        )
        dock.configFrames = dock.configFrames.upserting(entry)
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
        applyBackdropAppearance(appearance, to: panel)
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

    private static func configureStandardWindowButtons(in panel: NSWindow) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = panel.standardWindowButton(buttonType) else { continue }
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = buttonType != .zoomButton
            if buttonType == .miniaturizeButton,
               let floatingPanel = panel as? WorkspaceFloatingDockPanel {
                button.target = floatingPanel
                button.action = #selector(WorkspaceFloatingDockPanel.performCustomMinimize(_:))
                button.toolTip = String(
                    localized: "floatingDock.window.minimize",
                    defaultValue: "Minimize Floating Window"
                )
            }
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
    var onCustomMinimize: (() -> Void)?

    @objc func performCustomMinimize(_ sender: Any?) {
        onCustomMinimize?()
    }

    override func miniaturize(_ sender: Any?) {
        performCustomMinimize(sender)
    }

    override func zoom(_ sender: Any?) {}

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
}

/// Floating Dock controls should work on the first click even when another
/// cmux window is currently key, matching native titlebar control behavior.
private final class WorkspaceFloatingDockHostingView<Content: View>: UserSizedWindowHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

extension NSWindow {
    var usesWorkspaceFloatingDockGlassBackdrop: Bool {
        identifier?.rawValue.hasPrefix("cmux.workspace.float.") == true
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
