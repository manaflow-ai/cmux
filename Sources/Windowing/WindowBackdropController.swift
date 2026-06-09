import AppKit
import SwiftUI

enum WindowBackdropHostingPhase: String, Equatable {
    case opaqueWindowFill
    case transparentRootBackdrop
    case windowGlass
}

struct WindowBackdropGlassPlan {
    let tintColor: NSColor
    let style: WindowGlassEffect.Style
}

struct WindowBackdropPlan {
    let hostingPhase: WindowBackdropHostingPhase
    let windowBackgroundColor: NSColor
    let windowIsOpaque: Bool
    let rootPolicy: WindowBackdropPolicy
    let glass: WindowBackdropGlassPlan?
    let shouldApplyGhosttyCompositorBlur: Bool
    /// Full-window background image painted at the AppKit window level (under
    /// the titlebar + every surface). Empty path = no image theme.
    var backgroundImagePath: String = ""
    var backgroundImageOpacity: CGFloat = 0
    var backgroundImageFit: BackgroundImageFit = .cover
    /// Solid base painted behind the image so a low-opacity image blends over a
    /// dark surface (matches Warp's "image at N% over surface" look).
    var backgroundImageBaseColor: NSColor = .black

    var imageThemeActive: Bool { !backgroundImagePath.isEmpty }

    var usesTransparentWindow: Bool {
        hostingPhase != .opaqueWindowFill
    }

    var usesWindowGlass: Bool {
        hostingPhase == .windowGlass
    }

    var appKitMutationID: String {
        [
            hostingPhase.rawValue,
            windowBackgroundColor.hexString(includeAlpha: true),
            String(windowIsOpaque),
            rootPolicy.identityComponent,
            glass?.tintColor.hexString(includeAlpha: true) ?? "nil",
            glass.map { String(describing: $0.style) } ?? "nil",
            String(shouldApplyGhosttyCompositorBlur),
            backgroundImagePath,
            String(format: "%.3f", backgroundImageOpacity),
            backgroundImageFit.rawValue,
            backgroundImageBaseColor.hexString(includeAlpha: true),
        ].joined(separator: "|")
    }
}

struct WindowBackdropApplicationResult {
    let didChangeGlassRoot: Bool
    let usesWindowGlass: Bool
}

enum WindowBackdropController {
    static func apply(
        snapshot: WindowAppearanceSnapshot,
        to window: NSWindow,
        glassEffectAvailable: Bool = WindowGlassEffect.isAvailable
    ) -> WindowBackdropApplicationResult {
        apply(plan: snapshot.backdropPlan(glassEffectAvailable: glassEffectAvailable), to: window)
    }

    static func apply(
        plan: WindowBackdropPlan,
        to window: NSWindow
    ) -> WindowBackdropApplicationResult {
        var didChangeGlassRoot = false

        switch plan.hostingPhase {
        case .opaqueWindowFill:
            didChangeGlassRoot = WindowGlassEffect.remove(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = plan.windowIsOpaque
            cmuxResetCompositorBackgroundBlur(on: window)
        case .transparentRootBackdrop:
            didChangeGlassRoot = WindowGlassEffect.remove(from: window)
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            if plan.shouldApplyGhosttyCompositorBlur {
                GhosttyApp.shared.applyWindowBlurIfNeeded(window)
            } else {
                cmuxResetCompositorBackgroundBlur(on: window)
            }
        case .windowGlass:
            window.backgroundColor = plan.windowBackgroundColor
            window.isOpaque = false
            cmuxResetCompositorBackgroundBlur(on: window)
            if let glass = plan.glass {
                didChangeGlassRoot = WindowGlassEffect.apply(
                    to: window,
                    tintColor: glass.tintColor,
                    style: glass.style
                )
            } else {
                didChangeGlassRoot = WindowGlassEffect.remove(from: window)
            }
        }

        // Install/update or tear down the AppKit window-level background image
        // last so it re-asserts after any glass/backdrop mutation above. This
        // runs on every focus/selection re-apply, so the image persists.
        if plan.imageThemeActive {
            WindowBackgroundImageEffect.apply(
                to: window,
                image: BackgroundImageThemeStore.image(forPath: plan.backgroundImagePath),
                opacity: plan.backgroundImageOpacity,
                fit: plan.backgroundImageFit,
                baseColor: plan.backgroundImageBaseColor
            )
        } else {
            WindowBackgroundImageEffect.remove(from: window)
        }

        return WindowBackdropApplicationResult(
            didChangeGlassRoot: didChangeGlassRoot,
            usesWindowGlass: plan.usesWindowGlass
        )
    }

    static func updateGlassTint(to window: NSWindow, color: NSColor?) {
        WindowGlassEffect.updateTint(to: window, color: color)
    }
}

extension WindowAppearanceSnapshot {
    static func currentFromUserDefaults(
        defaults: UserDefaults = .standard,
        app: GhosttyApp = .shared,
        colorScheme: ColorScheme? = nil
    ) -> Self {
        current(
            unifySurfaceBackdrops: defaults.object(forKey: "sidebarMatchTerminalBackground") as? Bool ?? false,
            colorScheme: colorScheme ?? currentAppColorScheme(),
            sidebarMaterial: defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.withinWindow.rawValue,
            sidebarState: defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue,
            sidebarTintHex: defaults.string(forKey: "sidebarTintHex") ?? SidebarTintDefaults.hex,
            sidebarTintHexLight: defaults.string(forKey: "sidebarTintHexLight"),
            sidebarTintHexDark: defaults.string(forKey: "sidebarTintHexDark"),
            sidebarTintOpacity: defaults.object(forKey: "sidebarTintOpacity") as? Double ?? SidebarTintDefaults.opacity,
            sidebarCornerRadius: defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0.0,
            sidebarBlurOpacity: defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 1.0,
            bgGlassEnabled: defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false,
            bgGlassTintHex: defaults.string(forKey: "bgGlassTintHex") ?? "#000000",
            bgGlassTintOpacity: defaults.object(forKey: "bgGlassTintOpacity") as? Double ?? 0.03,
            backgroundImagePath: defaults.string(forKey: BackgroundImageThemeDefaults.pathKey) ?? "",
            backgroundImageOpacity: defaults.object(forKey: BackgroundImageThemeDefaults.opacityKey) as? Double
                ?? BackgroundImageThemeDefaults.defaultOpacity,
            backgroundImageFit: defaults.string(forKey: BackgroundImageThemeDefaults.fitKey)
                ?? BackgroundImageFit.cover.rawValue,
            app: app
        )
    }

    func replacingTerminalBackgroundColor(_ color: NSColor) -> Self {
        Self(
            terminalBackgroundColor: color,
            terminalBackgroundOpacity: terminalBackgroundOpacity,
            terminalBackgroundBlur: terminalBackgroundBlur,
            terminalRenderingMode: terminalRenderingMode,
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: sidebarSettings,
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: windowGlassSettings.sidebarBlendModeRawValue,
                isEnabled: windowGlassSettings.isEnabled,
                tintHex: windowGlassSettings.tintHex,
                tintOpacity: windowGlassSettings.tintOpacity,
                terminalBackgroundBlur: terminalBackgroundBlur,
                terminalGlassTintColor: color.withAlphaComponent(terminalBackgroundOpacity)
            ),
            backgroundImagePath: backgroundImagePath,
            backgroundImageOpacity: backgroundImageOpacity,
            backgroundImageFit: backgroundImageFit
        )
    }

    var appKitWindowMutationID: String {
        backdropPlan().appKitMutationID
    }

    func shouldUseTransparentHosting(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        backdropPlan(glassEffectAvailable: glassEffectAvailable).usesTransparentWindow
    }

    func backdropPlan(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> WindowBackdropPlan {
        let rootPolicy = terminalBackdropPolicy()
        // A full-window image theme takes priority: the window must be
        // transparent (no glass, no opaque fill) so the AppKit image view
        // installed in the theme frame shows through every surface, including
        // the native titlebar. Survives focus/selection because it rides the
        // same WindowBackdropController.apply chokepoint.
        if imageThemeActive {
            return WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: .clear,
                windowIsOpaque: false,
                rootPolicy: .clear,
                glass: nil,
                shouldApplyGhosttyCompositorBlur: false,
                backgroundImagePath: backgroundImagePath,
                backgroundImageOpacity: backgroundImageOpacity,
                backgroundImageFit: backgroundImageFit,
                backgroundImageBaseColor: terminalBackgroundColor
            )
        }
        if windowGlassSettings.shouldApply(glassEffectAvailable: glassEffectAvailable) {
            return WindowBackdropPlan(
                hostingPhase: .windowGlass,
                windowBackgroundColor: cmuxTransparentWindowBaseColor(),
                windowIsOpaque: false,
                rootPolicy: rootPolicy,
                glass: WindowBackdropGlassPlan(
                    tintColor: windowGlassSettings.tintColor,
                    style: windowGlassSettings.style
                ),
                shouldApplyGhosttyCompositorBlur: false
            )
        }

        if terminalBackgroundOpacity < 0.999 {
            return WindowBackdropPlan(
                hostingPhase: .transparentRootBackdrop,
                windowBackgroundColor: cmuxTransparentWindowBaseColor(),
                windowIsOpaque: false,
                rootPolicy: rootPolicy,
                glass: nil,
                shouldApplyGhosttyCompositorBlur: !terminalBackgroundBlur.isMacOSGlassStyle
            )
        }

        return WindowBackdropPlan(
            hostingPhase: .opaqueWindowFill,
            windowBackgroundColor: compositedTerminalBackgroundColor,
            windowIsOpaque: true,
            rootPolicy: rootPolicy,
            glass: nil,
            shouldApplyGhosttyCompositorBlur: false
        )
    }

    private static func currentAppColorScheme(
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

private extension WindowBackdropPolicy {
    var identityComponent: String {
        switch self {
        case let .ghosttyTerminalBackdrop(color, opacity, renderingMode):
            return [
                "ghosttyTerminalBackdrop",
                color.hexString(includeAlpha: true),
                String(format: "%.4f", Double(opacity)),
                String(describing: renderingMode),
            ].joined(separator: ":")
        case let .sidebarMaterial(materialPolicy):
            return [
                "sidebarMaterial",
                String(describing: materialPolicy.material),
                String(describing: materialPolicy.blendingMode),
                String(describing: materialPolicy.state),
                String(format: "%.4f", materialPolicy.opacity),
                materialPolicy.tintColor.hexString(includeAlpha: true),
                String(format: "%.4f", Double(materialPolicy.cornerRadius)),
                String(materialPolicy.preferLiquidGlass),
                String(materialPolicy.usesWindowLevelGlass),
            ].joined(separator: ":")
        case .clear:
            return "clear"
        }
    }
}

/// Paints a full-window background image at the AppKit window level by
/// inserting a layer-backed view into the window's theme frame
/// (`contentView.superview`), below the SwiftUI hosting view and the native
/// titlebar. Mirrors `WindowGlassEffect`'s fallback install pattern so the
/// image covers the titlebar + sidebar + terminal continuously (Warp-style)
/// and survives focus/selection re-applies. A solid base color sits behind the
/// image so a low-opacity image blends over a dark surface.
enum WindowBackgroundImageEffect {
    static let viewIdentifier = NSUserInterfaceItemIdentifier("cmux.windowBackgroundImage")

    private final class BackgroundImageView: NSView {
        private let baseLayer = CALayer()
        private let imageLayer = CALayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            identifier = WindowBackgroundImageEffect.viewIdentifier
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            layer?.isOpaque = false
            layer?.addSublayer(baseLayer)
            layer?.addSublayer(imageLayer)
            baseLayer.masksToBounds = true
            imageLayer.masksToBounds = true
            imageLayer.actions = ["contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            baseLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            baseLayer.frame = bounds
            imageLayer.frame = bounds
            CATransaction.commit()
        }

        func configure(image: NSImage?, opacity: CGFloat, fit: BackgroundImageFit, baseColor: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            baseLayer.backgroundColor = baseColor.cgColor
            if let image,
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageLayer.contents = cg
                imageLayer.contentsGravity = fit == .cover ? .resizeAspectFill : .resizeAspect
                imageLayer.opacity = Float(max(0, min(1, opacity)))
            } else {
                imageLayer.contents = nil
                imageLayer.opacity = 0
            }
            CATransaction.commit()
        }
    }

    static func apply(
        to window: NSWindow,
        image: NSImage?,
        opacity: CGFloat,
        fit: BackgroundImageFit,
        baseColor: NSColor
    ) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }

        if let existing = themeFrame.subviews.first(where: { $0.identifier == viewIdentifier }) as? BackgroundImageView {
            existing.configure(image: image, opacity: opacity, fit: fit, baseColor: baseColor)
            return
        }

        let view = BackgroundImageView(frame: themeFrame.bounds)
        attach(view, to: themeFrame, below: contentView)
        view.configure(image: image, opacity: opacity, fit: fit, baseColor: baseColor)
    }

    static func remove(from window: NSWindow) {
        guard let themeFrame = window.contentView?.superview else { return }
        themeFrame.subviews
            .filter { $0.identifier == viewIdentifier }
            .forEach { $0.removeFromSuperview() }
    }

    private static func attach(_ view: NSView, to themeFrame: NSView, below contentView: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(view, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            view.bottomAnchor.constraint(equalTo: themeFrame.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
        ])
    }
}
