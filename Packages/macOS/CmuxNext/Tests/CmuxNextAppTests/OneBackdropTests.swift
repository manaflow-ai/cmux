import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextApps
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import CmuxNextSettingsWindow
import Testing

extension AppThemeGlobalStateTests {
/// One backdrop per window (plans/cmux-next/windows.md, Lawrence R31): with
/// a see-through theme (background-opacity < 1, blur on) the main window
/// has exactly one translucent backdrop, the root's material and tint,
/// and every surface above it (sidebar, panes, strips, titlebar, docks)
/// is clear, so everything reads as the same color. At opacity 1 the
/// surfaces draw the token or stay clear. Beside the leading rail the
/// sidebar and main pane share the rounded frame in
/// `WindowSidebarPanelView`; the frame uses the same surface token.
@MainActor
@Suite(.serialized)
struct OneBackdropTests {
    /// A surface: a view that covers a large part of the window (a fill
    /// there reads as a second background, not as a control or a mark).
    private static func isSurface(_ view: NSView, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let frame = view.convert(view.bounds, to: content)
        let area = content.bounds.width * content.bounds.height
        return area > 0 && frame.width * frame.height >= area * 0.04
    }

    /// The fill a view paints behind its subviews, if any is visible.
    private static func fill(of view: NSView) -> String? {
        // Invisible views and layers that only serve as another layer's mask draw nothing.
        if view.isHiddenOrHasHiddenAncestor || view.alphaValue < 0.01 || (view.layer?.opacity ?? 1) < 0.01 { return nil }
        if let layer = view.layer, layer.superlayer?.mask === layer { return nil }
        if let color = view.layer?.backgroundColor, color.alpha > 0.002 { return "layer \(color)" }
        if let scroll = view as? NSScrollView, scroll.drawsBackground, scroll.backgroundColor.alphaComponent > 0 { return "scroll view" }
        if let clip = view as? NSClipView, clip.drawsBackground, clip.backgroundColor.alphaComponent > 0 { return "clip view" }
        if let text = view as? NSTextField, text.drawsBackground, (text.backgroundColor?.alphaComponent ?? 0) > 0 { return "text field" }
        if let box = view as? NSBox, box.boxType == .custom, !box.isTransparent, box.fillColor.alphaComponent > 0 { return "box" }
        return nil
    }

    /// Every surface view under `view` that paints a fill, skipping the backdrop.
    private static func filledSurfaces(_ view: NSView, in window: NSWindow, skipping backdrop: NSView) -> [String] {
        if view === backdrop || view.isHidden || view is WindowSidebarPanelView { return [] }
        var found: [String] = []
        if isSurface(view, in: window), let fill = fill(of: view) {
            var chain: [String] = []
            var up = view.superview
            while let parent = up, chain.count < 4 { chain.append(String(describing: type(of: parent))); up = parent.superview }
            found.append("\(type(of: view)) \(view.frame) in \(chain.joined(separator: "<")): \(fill)")
        }
        for sub in view.subviews { found += filledSurfaces(sub, in: window, skipping: backdrop) }
        return found
    }

    private func mainWindow(opacity: Double, blur: Int) async throws -> (WindowController, WindowRootView) {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let controller = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        var input = ThemeScope.app.input
        input.backgroundOpacity = opacity
        input.backgroundBlur = blur
        controller.themeScope.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let root = try #require(window.contentView as? WindowRootView)
        return (controller, root)
    }

    @Test func aSeeThroughMainWindowHasExactlyOneBackdrop() async throws {
        let (controller, root) = try await mainWindow(opacity: 0.6, blur: 20)
        let window = try #require(controller.window)
        #expect(!root.backdrop.isOpaque)
        #expect(!window.isOpaque)
        #expect((window.backgroundColor?.alphaComponent ?? 1) < 0.01, "the window itself stays clear")
        #expect(root.backdropView.tintColor != nil, "the one backdrop: the root's tint")
        #expect(root.layer?.backgroundColor == nil, "the root paints nothing over its backdrop")
        let filled = Self.filledSurfaces(root, in: window, skipping: root.backdropView)
        #expect(filled.isEmpty, "surfaces with their own fill over the backdrop: \(filled)")
    }

    @Test func anOpaqueMainWindowsSurfacesDrawTheTokenOrNothing() async throws {
        let (controller, root) = try await mainWindow(opacity: 1, blur: 0)
        let window = try #require(controller.window)
        let token = root.themeTokens.surfaceBackground.withAlpha(1)
        var offenders: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden, !(view is WindowSidebarPanelView) else { return }
            if Self.isSurface(view, in: window), let color = view.layer?.backgroundColor, color.alpha > 0.002,
               let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB),
               abs(rgb.redComponent - token.red) > 0.004 || abs(rgb.greenComponent - token.green) > 0.004
               || abs(rgb.blueComponent - token.blue) > 0.004 || rgb.alphaComponent < 0.999 {
                offenders.append("\(type(of: view)) \(rgb)")
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        #expect(offenders.isEmpty, "surfaces that are neither the token nor clear: \(offenders)")
    }

    /// The real windows of their own that tests can build, plus every other
    /// kind through the window kit.
    private func ownWindows() async throws -> [(WindowKind, NSWindow)] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-one-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let registry = ActionRegistry(catalog: [])
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        await settings.reload()
        var windows: [(WindowKind, NSWindow)] = []
        let settingsWindow = SettingsWindowController(model: SettingsWindowModel(settings: settings, registry: registry, host: nil))
        windows.append((.settings, try #require(settingsWindow.window)))
        let debug = DebugSettingsWindowController(model: DebugSettingsModel(store: TunableStore(), descriptors: []))
        windows.append((.debugSettings, try #require(debug.window)))
        let appRoot = directory.appending(path: "apps")
        let apps = AppRegistry(directory: appRoot, firstPartyRoot: appRoot.appending(path: "none"))
        let store = AppStoreWindowController(model: AppStoreModel(catalog: RegistryAppStoreCatalog(registry: apps), registry: apps,
                                                                  host: AppHost(sink: AppPreviewSink()), previewHost: AppHost(sink: AppPreviewSink())))
        windows.append((.appStore, try #require(store.window)))
        let onboardingServices = MockOnboardingServices()
        onboardingServices.accountsView = NSView()
        onboardingServices.firstTaskView = NSView()
        let onboarding = OnboardingWindowController(model: OnboardingModel(services: onboardingServices, start: .role))
        windows.append((.onboarding, try #require(onboarding.window)))
        for kind in WindowKind.allCases where kind != .main && !windows.contains(where: { $0.0 == kind }) {
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 480, height: 320),
                                  styleMask: [.resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.install(kind: kind, content: NSView(), scope: .app)
            windows.append((kind, window))
        }
        return windows
    }

    /// Every kind, see-through: the window kit's one backdrop (the tint at
    /// the theme's opacity over a clear window) and no surface above it
    /// with a fill of its own.
    @Test func everyWindowKindHasExactlyOneBackdrop() async throws {
        _ = NSApplication.shared
        var input = ThemeScope.app.input
        input.backgroundOpacity = 0.6
        input.backgroundBlur = 20
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let windows = try await ownWindows()
        #expect(Set(windows.map(\.0)) == Set(WindowKind.allCases).subtracting([.main]))
        for (kind, window) in windows {
            room.adopt(window)
            window.contentView?.layoutSubtreeIfNeeded()
            let surface = try #require(window.contentView as? WindowSurfaceView, "\(kind)")
            #expect(!window.isOpaque && (window.backgroundColor?.alphaComponent ?? 1) < 0.01, "\(kind)")
            #expect(surface.backdropView.tintColor != nil, "\(kind): the one backdrop")
            #expect(surface.layer?.backgroundColor == nil, "\(kind)")
            let filled = Self.filledSurfaces(surface, in: window, skipping: surface.backdropView)
            #expect(filled.isEmpty, "\(kind): surfaces with their own fill over the backdrop: \(filled)")
        }
    }
}
}
