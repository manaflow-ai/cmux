import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Owns the native child panel for one workspace floating Dock.
@MainActor
final class WorkspaceFloatingDockWindowController: NSWindowController, NSWindowDelegate {
    let dock: WorkspaceFloatingDock
    private weak var parentWindow: NSWindow?
    private let onCloseRequest: (UUID) -> Void
    private let glassEffect = WindowGlassEffect()
    private let glassBackdropPanel: WorkspaceFloatingDockGlassBackdropPanel
    private weak var compatibilityBlurView: NSVisualEffectView?
    private var isApplyingModelFrame = false

    var glassBackdropWindowForTesting: NSWindow {
        glassBackdropPanel
    }

    init(
        dock: WorkspaceFloatingDock,
        parentWindow: NSWindow,
        onCloseRequest: @escaping (UUID) -> Void
    ) {
        self.dock = dock
        self.parentWindow = parentWindow
        self.onCloseRequest = onCloseRequest

        let panel = NSPanel(
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
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.contentView = WorkspaceFloatingDockHostingView(
            rootView: WorkspaceFloatingDockContentView(
                dock: dock
            ),
            minimumContentSize: NSSize(width: 320, height: 220)
        )

        let glassBackdropPanel = WorkspaceFloatingDockGlassBackdropPanel(
            contentRect: panel.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        glassBackdropPanel.titleVisibility = .hidden
        glassBackdropPanel.titlebarAppearsTransparent = true
        Self.hideStandardWindowButtons(in: glassBackdropPanel)
        glassBackdropPanel.identifier = NSUserInterfaceItemIdentifier(
            "cmux.workspace.floatGlass.\(dock.id.uuidString)"
        )
        glassBackdropPanel.isReleasedWhenClosed = false
        glassBackdropPanel.isFloatingPanel = false
        glassBackdropPanel.hidesOnDeactivate = false
        glassBackdropPanel.level = .normal
        glassBackdropPanel.collectionBehavior = [.fullScreenAuxiliary]
        glassBackdropPanel.isOpaque = false
        glassBackdropPanel.backgroundColor = .clear
        glassBackdropPanel.hasShadow = true
        glassBackdropPanel.ignoresMouseEvents = true
        glassBackdropPanel.isExcludedFromWindowsMenu = true
        glassBackdropPanel.contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        glassBackdropPanel.contentView?.wantsLayer = true
        glassBackdropPanel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        self.glassBackdropPanel = glassBackdropPanel
        super.init(window: panel)
        panel.delegate = self
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
        applyModelFrameIfNeeded()
        if !panel.isVisible {
            if panel.parent !== parentWindow {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            attachGlassBackdrop(to: panel)
            panel.orderFront(nil)
        } else if glassBackdropPanel.parent !== panel {
            attachGlassBackdrop(to: panel)
        }
        dock.isPresented = true
        dock.store.setVisibleInUI(true)
        if focus {
            if panel.isMiniaturized {
                panel.deminiaturize(nil)
            }
            panel.makeKeyAndOrderFront(nil)
            _ = dock.store.focusFirstControl()
        }
    }

    func hide() {
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        glassBackdropPanel.orderOut(nil)
        window?.orderOut(nil)
    }

    func teardown() {
        dock.ownsInputFocus = false
        dock.store.setVisibleInUI(false)
        if let window, let parent = window.parent {
            parent.removeChildWindow(window)
        }
        if glassBackdropPanel.parent != nil {
            glassBackdropPanel.parent?.removeChildWindow(glassBackdropPanel)
        }
        glassEffect.remove(from: glassBackdropPanel)
        compatibilityBlurView?.removeFromSuperview()
        glassBackdropPanel.orderOut(nil)
        window?.orderOut(nil)
        window?.delegate = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequest(dock.id)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        syncGlassBackdropFrame()
        captureModelFrame()
    }

    func windowDidResize(_ notification: Notification) {
        syncGlassBackdropFrame()
        captureModelFrame()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(320, frameSize.width), height: max(220, frameSize.height))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let panel = notification.object as? NSWindow {
            Self.configureStandardWindowButtons(in: panel)
        }
        dock.ownsInputFocus = true
    }

    func windowDidUpdate(_ notification: Notification) {
        if let panel = notification.object as? NSWindow {
            Self.configureStandardWindowButtons(in: panel)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dock.ownsInputFocus = false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        glassBackdropPanel.orderOut(nil)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let panel = window, panel.isVisible else { return }
        attachGlassBackdrop(to: panel)
        panel.orderFront(nil)
    }

    private func applyModelFrame() {
        guard let panel = window, let parentWindow else { return }
        isApplyingModelFrame = true
        panel.setFrame(Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow), display: false)
        syncGlassBackdropFrame()
        isApplyingModelFrame = false
    }

    private func applyModelFrameIfNeeded() {
        guard let panel = window, let parentWindow else { return }
        let target = Self.screenFrame(relativeFrame: dock.frame, parentWindow: parentWindow)
        guard panel.frame != target else { return }
        applyModelFrame()
    }

    private func captureModelFrame() {
        guard !isApplyingModelFrame, let panel = window, let parentWindow else { return }
        dock.frame = CGRect(
            x: panel.frame.minX - parentWindow.frame.minX,
            y: panel.frame.minY - parentWindow.frame.minY,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    private func attachGlassBackdrop(to panel: NSWindow) {
        syncGlassBackdropFrame()
        if glassBackdropPanel.parent !== panel {
            glassBackdropPanel.parent?.removeChildWindow(glassBackdropPanel)
            panel.addChildWindow(glassBackdropPanel, ordered: .below)
        }
        glassBackdropPanel.orderFront(nil)
        glassBackdropPanel.order(.below, relativeTo: panel.windowNumber)
    }

    private func syncGlassBackdropFrame() {
        guard let panel = window, glassBackdropPanel.frame != panel.frame else { return }
        glassBackdropPanel.setFrame(panel.frame, display: false)
    }

    private func applyGlassTexture() {
        glassEffect.remove(from: glassBackdropPanel)
        compatibilityBlurView?.removeFromSuperview()

#if DEBUG
        let texture = WorkspaceFloatingDockTextureDebugSettings.currentStyle()
        if let liquidGlass = texture.liquidGlass {
            glassEffect.apply(
                to: glassBackdropPanel,
                tintColor: liquidGlass.tint,
                style: liquidGlass.style
            )
        } else if let material = texture.compatibilityMaterial {
            applyCompatibilityBlur(material: material)
        }
#else
        glassEffect.apply(to: glassBackdropPanel, tintColor: nil, style: .regular)
#endif
    }

    private func applyCompatibilityBlur(material: NSVisualEffectView.Material) {
        guard let contentView = glassBackdropPanel.contentView else { return }
        let blurView = NSVisualEffectView(frame: contentView.bounds)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.material = material
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        contentView.addSubview(blurView)
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: contentView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
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

    private static func hideStandardWindowButtons(in panel: NSWindow) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = panel.standardWindowButton(buttonType) else { continue }
            button.isHidden = true
            button.alphaValue = 0
            button.isEnabled = false
        }
    }

    private static func configureStandardWindowButtons(in panel: NSWindow) {
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = panel.standardWindowButton(buttonType) else { continue }
            button.isHidden = false
            button.alphaValue = 1
            button.isEnabled = buttonType == .closeButton
        }
    }
}

/// Hosts only the visual material. Keeping this panel permanently non-key
/// prevents native Liquid Glass from changing when the interactive Dock panel
/// gains or loses focus.
private final class WorkspaceFloatingDockGlassBackdropPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Floating Dock controls should work on the first click even when another
/// cmux window is currently key, matching native titlebar control behavior.
private final class WorkspaceFloatingDockHostingView<Content: View>: UserSizedWindowHostingView<Content> {
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
        case .regular:
            (.regular, nil)
        case .clear:
            (.clear, nil)
        case .smoke:
            (.regular, NSColor.black.withAlphaComponent(0.12))
        case .frosted:
            (.regular, NSColor.white.withAlphaComponent(0.08))
        case .warm:
            (.regular, NSColor.systemOrange.withAlphaComponent(0.08))
        case .cool:
            (.regular, NSColor.systemBlue.withAlphaComponent(0.08))
        case .underWindow, .hud, .sidebar, .popover, .menu, .titlebar, .contentBackground, .transparent:
            nil
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
        case .regular, .clear, .smoke, .frosted, .warm, .cool, .transparent:
            nil
        }
    }
}

enum WorkspaceFloatingDockTextureDebugSettings {
    static let styleKey = "debugWorkspaceFloatingDockTextureStyle"
    static let defaultStyle = WorkspaceFloatingDockTextureDebugStyle.regular

    static func currentStyle(defaults: UserDefaults = .standard) -> WorkspaceFloatingDockTextureDebugStyle {
        WorkspaceFloatingDockTextureDebugStyle(rawValue: defaults.string(forKey: styleKey) ?? "") ?? defaultStyle
    }
}

final class WorkspaceFloatingDockTextureDebugWindowController: ReleasingWindowController {
    static let shared = WorkspaceFloatingDockTextureDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
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
    @AppStorage(WorkspaceFloatingDockTextureDebugSettings.styleKey)
    private var styleRawValue = WorkspaceFloatingDockTextureDebugSettings.defaultStyle.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("debug.floatingDockTexture.heading")
                .cmuxFont(.headline)

            GroupBox("debug.floatingDockTexture.group") {
                Picker("debug.floatingDockTexture.picker", selection: $styleRawValue) {
                    ForEach(WorkspaceFloatingDockTextureDebugStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)
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
        .onChange(of: styleRawValue) {
            AppDelegate.shared?.refreshAllWorkspaceFloatingDocks()
        }
    }
}
#endif
