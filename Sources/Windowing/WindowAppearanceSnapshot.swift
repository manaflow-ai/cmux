import AppKit
import SwiftUI

enum GhosttyTerminalBackdropRenderingMode {
    case windowHostBackdrop
    case ghosttyRendererOwnedBackgroundImage

    var usesWindowHostBackdrop: Bool {
        self == .windowHostBackdrop
    }
}

enum WindowBackdropRole {
    case windowRoot
    case terminalCanvas
    case bonsplitChrome
    case titlebar
    case leftSidebar
    case rightSidebar
    case browserSurface
}

enum GhosttyBackgroundBlur: Equatable {
    case disabled
    case radius(Int)
    case macosGlassRegular
    case macosGlassClear

    init(cValue value: Int16) {
        switch value {
        case 0:
            self = .disabled
        case -1:
            self = .macosGlassRegular
        case -2:
            self = .macosGlassClear
        case 1...:
            self = .radius(Int(value))
        default:
            self = .disabled
        }
    }

    var isMacOSGlassStyle: Bool {
        switch self {
        case .macosGlassRegular, .macosGlassClear:
            return true
        case .disabled, .radius:
            return false
        }
    }

    var windowGlassStyle: WindowGlassEffect.Style? {
        switch self {
        case .macosGlassRegular:
            return .regular
        case .macosGlassClear:
            return .clear
        case .disabled, .radius:
            return nil
        }
    }
}

struct SidebarBackdropMaterialPolicy {
    let material: NSVisualEffectView.Material?
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let opacity: Double
    let tintColor: NSColor
    let cornerRadius: CGFloat
    let preferLiquidGlass: Bool
    let usesWindowLevelGlass: Bool
}

enum WindowBackdropPolicy {
    case ghosttyTerminalBackdrop(
        color: NSColor,
        opacity: CGFloat,
        renderingMode: GhosttyTerminalBackdropRenderingMode
    )
    case sidebarMaterial(SidebarBackdropMaterialPolicy)
    case clear

    var hostLayerBackgroundColor: NSColor? {
        switch self {
        case let .ghosttyTerminalBackdrop(color, opacity, renderingMode):
            guard renderingMode.usesWindowHostBackdrop else { return nil }
            return color.withAlphaComponent(opacity)
        case .sidebarMaterial, .clear:
            return nil
        }
    }
}

/// Identifies the layer responsible for painting a terminal surface background.
enum TerminalSurfaceBackgroundFillOwner: Equatable {
    /// The terminal hosting view should paint the resolved background color.
    case surfaceHostLayer

    /// The shared root backdrop should remain the only visible background fill.
    case sharedWindowBackdrop

    /// The Bonsplit pane backdrop should remain the only visible background fill.
    case bonsplitPaneBackdrop

    /// Ghostty's renderer owns the background instead of cmux's host layers.
    case ghosttyNativeRenderer
}

/// Resolved background painting decision for one terminal surface.
struct TerminalSurfaceBackgroundFillPlan {
    /// The layer or renderer that owns the visible terminal background.
    let owner: TerminalSurfaceBackgroundFillOwner

    /// The color to apply to the terminal host layer, or clear when another layer owns the fill.
    let hostLayerColor: NSColor

    /// Whether a host-layer fill must subtract itself from the shared window backdrop.
    let clearsSharedWindowBackdrop: Bool

    /// Whether the terminal host layer should paint a non-clear fill.
    var usesHostLayerFill: Bool {
        owner == .surfaceHostLayer
    }

    /// Compact label used by debug logging for the selected backdrop owner.
    var logBackdropLabel: String {
        switch owner {
        case .surfaceHostLayer:
            return "terminal"
        case .sharedWindowBackdrop:
            return "shared"
        case .bonsplitPaneBackdrop:
            return "bonsplit-pane"
        case .ghosttyNativeRenderer:
            return "ghostty-native"
        }
    }

    /// Returns the debug-log source label for the selected owner.
    func logSource(hasSurfaceOverride: Bool) -> String {
        switch owner {
        case .surfaceHostLayer:
            return hasSurfaceOverride ? "surfaceOverride" : "defaultBackground"
        case .sharedWindowBackdrop:
            return "sharedWindowBackdrop"
        case .bonsplitPaneBackdrop:
            return "bonsplitPaneBackdrop"
        case .ghosttyNativeRenderer:
            return "ghosttyNativeBackground"
        }
    }

    /// Computes the terminal background owner and host-layer color for current appearance state.
    static func resolve(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        surfaceBackgroundColor: NSColor?,
        defaultBackgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool,
        usesBonsplitPaneBackdrop: Bool
    ) -> Self {
        let resolvedColor = (surfaceBackgroundColor ?? defaultBackgroundColor)
            .withAlphaComponent(WindowAppearanceSnapshot.clampedOpacity(backgroundOpacity))
        let owner: TerminalSurfaceBackgroundFillOwner
        let usesPaneLocalSurfaceFill = surfaceBackgroundColor != nil &&
            renderingMode.usesWindowHostBackdrop &&
            !usesBonsplitPaneBackdrop
        if !renderingMode.usesWindowHostBackdrop {
            owner = .ghosttyNativeRenderer
        } else if usesPaneLocalSurfaceFill {
            owner = .surfaceHostLayer
        } else if !sharesWindowBackdrop && !usesBonsplitPaneBackdrop {
            owner = .surfaceHostLayer
        } else if sharesWindowBackdrop {
            owner = .sharedWindowBackdrop
        } else {
            owner = .bonsplitPaneBackdrop
        }
        return Self(
            owner: owner,
            hostLayerColor: owner == .surfaceHostLayer ? resolvedColor : .clear,
            clearsSharedWindowBackdrop: usesPaneLocalSurfaceFill && sharesWindowBackdrop
        )
    }
}

struct SidebarBackdropSettingsSnapshot {
    let materialRawValue: String
    let blendModeRawValue: String
    let stateRawValue: String
    let tintHex: String
    let tintHexLight: String?
    let tintHexDark: String?
    let tintOpacity: Double
    let cornerRadius: Double
    let blurOpacity: Double
    let colorScheme: ColorScheme

    var materialPolicy: SidebarBackdropMaterialPolicy {
        let materialOption = SidebarMaterialOption(rawValue: materialRawValue)
        let blendingMode = SidebarBlendModeOption(rawValue: blendModeRawValue)?.mode ?? .behindWindow
        let state = SidebarStateOption(rawValue: stateRawValue)?.state ?? .active
        let resolvedHex: String
        if colorScheme == .dark, let tintHexDark {
            resolvedHex = tintHexDark
        } else if colorScheme == .light, let tintHexLight {
            resolvedHex = tintHexLight
        } else {
            resolvedHex = tintHex
        }
        let tintColor = (NSColor(hex: resolvedHex) ?? NSColor(hex: tintHex) ?? .black)
            .withAlphaComponent(tintOpacity)
        let preferLiquidGlass = materialOption?.usesLiquidGlass ?? false
        let usesWindowLevelGlass = preferLiquidGlass && blendingMode == .behindWindow

        return SidebarBackdropMaterialPolicy(
            material: materialOption?.material,
            blendingMode: blendingMode,
            state: state,
            opacity: blurOpacity,
            tintColor: tintColor,
            cornerRadius: CGFloat(max(0, cornerRadius)),
            preferLiquidGlass: preferLiquidGlass,
            usesWindowLevelGlass: usesWindowLevelGlass
        )
    }

    var appKitMutationID: String {
        [
            materialRawValue,
            blendModeRawValue,
            stateRawValue,
            tintHex,
            tintHexLight ?? "nil",
            tintHexDark ?? "nil",
            Self.identityComponent(tintOpacity),
            Self.identityComponent(cornerRadius),
            Self.identityComponent(blurOpacity),
            String(describing: colorScheme),
        ].joined(separator: "|")
    }

    private static func identityComponent(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

struct WindowGlassSettingsSnapshot {
    let sidebarBlendModeRawValue: String
    let isEnabled: Bool
    let tintHex: String
    let tintOpacity: Double
    let terminalBackgroundBlur: GhosttyBackgroundBlur
    let terminalGlassTintColor: NSColor?

    init(
        sidebarBlendModeRawValue: String,
        isEnabled: Bool,
        tintHex: String,
        tintOpacity: Double,
        terminalBackgroundBlur: GhosttyBackgroundBlur = .disabled,
        terminalGlassTintColor: NSColor? = nil
    ) {
        self.sidebarBlendModeRawValue = sidebarBlendModeRawValue
        self.isEnabled = isEnabled
        self.tintHex = tintHex
        self.tintOpacity = tintOpacity
        self.terminalBackgroundBlur = terminalBackgroundBlur
        self.terminalGlassTintColor = terminalGlassTintColor
    }

    var tintColor: NSColor {
        if let terminalGlassTintColor, terminalBackgroundBlur.isMacOSGlassStyle {
            return terminalGlassTintColor
        }
        return (NSColor(hex: tintHex) ?? .black).withAlphaComponent(tintOpacity)
    }

    var style: WindowGlassEffect.Style {
        terminalBackgroundBlur.windowGlassStyle ?? .regular
    }

    func shouldApply(glassEffectAvailable: Bool = WindowGlassEffect.isAvailable) -> Bool {
        if terminalBackgroundBlur.isMacOSGlassStyle {
            return true
        }
        return cmuxShouldApplyWindowGlass(
            sidebarBlendMode: sidebarBlendModeRawValue,
            bgGlassEnabled: isEnabled,
            glassEffectAvailable: glassEffectAvailable
        )
    }

    var appKitMutationID: String {
        [
            sidebarBlendModeRawValue,
            String(isEnabled),
            tintHex,
            String(format: "%.4f", tintOpacity),
            String(describing: terminalBackgroundBlur),
            terminalGlassTintColor?.hexString(includeAlpha: true) ?? "nil",
        ].joined(separator: "|")
    }
}

struct WindowAppearanceSnapshot {
    let terminalBackgroundColor: NSColor
    let terminalBackgroundOpacity: CGFloat
    let terminalBackgroundBlur: GhosttyBackgroundBlur
    let terminalRenderingMode: GhosttyTerminalBackdropRenderingMode
    let unifySurfaceBackdrops: Bool
    let sidebarSettings: SidebarBackdropSettingsSnapshot
    let windowGlassSettings: WindowGlassSettingsSnapshot
    /// Resolved (tilde-expanded handled by the store) path of the full-window
    /// background image. Empty when no image theme is active.
    let backgroundImagePath: String
    let backgroundImageOpacity: CGFloat
    let backgroundImageFit: BackgroundImageFit

    /// Whether a full-window background image theme is active. When true, the
    /// sidebar/chrome backdrops are forced transparent so the single image
    /// shows through every surface (Warp-style unified background).
    var imageThemeActive: Bool { !backgroundImagePath.isEmpty }

    static func current(
        unifySurfaceBackdrops: Bool,
        colorScheme: ColorScheme,
        sidebarMaterial: String,
        sidebarBlendMode: String,
        sidebarState: String,
        sidebarTintHex: String,
        sidebarTintHexLight: String?,
        sidebarTintHexDark: String?,
        sidebarTintOpacity: Double,
        sidebarCornerRadius: Double,
        sidebarBlurOpacity: Double,
        bgGlassEnabled: Bool,
        bgGlassTintHex: String,
        bgGlassTintOpacity: Double,
        backgroundImagePath: String = "",
        backgroundImageOpacity: Double = BackgroundImageThemeDefaults.defaultOpacity,
        backgroundImageFit: String = BackgroundImageFit.cover.rawValue,
        app: GhosttyApp = .shared
    ) -> Self {
        Self(
            terminalBackgroundColor: app.defaultBackgroundColor,
            terminalBackgroundOpacity: Self.clampedOpacity(app.defaultBackgroundOpacity),
            terminalBackgroundBlur: app.defaultBackgroundBlur,
            terminalRenderingMode: Self.terminalRenderingMode(
                usesHostLayerBackground: app.usesHostLayerBackground
            ),
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: sidebarMaterial,
                blendModeRawValue: sidebarBlendMode,
                stateRawValue: sidebarState,
                tintHex: sidebarTintHex,
                tintHexLight: sidebarTintHexLight,
                tintHexDark: sidebarTintHexDark,
                tintOpacity: sidebarTintOpacity,
                cornerRadius: sidebarCornerRadius,
                blurOpacity: sidebarBlurOpacity,
                colorScheme: colorScheme
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: sidebarBlendMode,
                isEnabled: bgGlassEnabled,
                tintHex: bgGlassTintHex,
                tintOpacity: bgGlassTintOpacity,
                terminalBackgroundBlur: app.defaultBackgroundBlur,
                terminalGlassTintColor: app.defaultBackgroundColor.withAlphaComponent(
                    Self.clampedOpacity(app.defaultBackgroundOpacity)
                )
            ),
            backgroundImagePath: backgroundImagePath,
            backgroundImageOpacity: Self.clampedOpacity(backgroundImageOpacity),
            backgroundImageFit: BackgroundImageFit(rawValueOrCover: backgroundImageFit)
        )
    }

    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0.0, min(1.0, opacity)))
    }

    static func compositedTerminalColor(
        backgroundColor: NSColor,
        opacity: Double,
        over baseColor: NSColor = .windowBackgroundColor
    ) -> NSColor {
        cmuxCompositedNSColor(
            backgroundColor.withAlphaComponent(clampedOpacity(opacity)),
            over: baseColor
        )
    }

    static func terminalRenderingMode(
        usesHostLayerBackground: Bool
    ) -> GhosttyTerminalBackdropRenderingMode {
        usesHostLayerBackground ? .windowHostBackdrop : .ghosttyRendererOwnedBackgroundImage
    }

    var compositedTerminalBackgroundColor: NSColor {
        Self.compositedTerminalColor(
            backgroundColor: terminalBackgroundColor,
            opacity: terminalBackgroundOpacity
        )
    }

    var chromeColorScheme: ColorScheme {
        // In image mode the terminal is fully transparent, so the composited
        // color is near-clear and would misresolve. Read text contrast from the
        // opaque preset background instead, keeping sidebar/terminal text legible
        // regardless of how transparent the terminal surface is.
        if imageThemeActive {
            return cmuxReadableColorScheme(for: terminalBackgroundColor)
        }
        return cmuxReadableColorScheme(for: compositedTerminalBackgroundColor)
    }

    /// Chrome/sidebar surfaces are unified (transparent) when the user opted
    /// into match-terminal-background OR a full-window image theme is active.
    var surfacesAreUnified: Bool {
        unifySurfaceBackdrops || imageThemeActive
    }

    var sidebarContentColorScheme: ColorScheme {
        surfacesAreUnified ? chromeColorScheme : sidebarSettings.colorScheme
    }

    func policy(for role: WindowBackdropRole) -> WindowBackdropPolicy {
        switch role {
        case .windowRoot:
            // With an image theme, the AppKit window-level image owns the
            // background; the SwiftUI root must stay clear so it doesn't paint
            // an opaque terminal color over the image.
            return imageThemeActive ? .clear : terminalBackdropPolicy()
        case .terminalCanvas, .bonsplitChrome, .titlebar, .browserSurface:
            return .clear
        case .leftSidebar, .rightSidebar:
            if surfacesAreUnified {
                return .clear
            }
            return .sidebarMaterial(sidebarSettings.materialPolicy)
        }
    }

    func terminalBackdropPolicy() -> WindowBackdropPolicy {
        if terminalBackgroundBlur.isMacOSGlassStyle {
            return .clear
        }
        return .ghosttyTerminalBackdrop(
            color: terminalBackgroundColor,
            opacity: terminalBackgroundOpacity,
            renderingMode: terminalRenderingMode
        )
    }
}

// MARK: - Background image theme

/// How a full-window background image is scaled to fill the window.
enum BackgroundImageFit: String, CaseIterable, Identifiable {
    case cover
    case contain

    var id: String { rawValue }

    init(rawValueOrCover raw: String?) {
        self = BackgroundImageFit(rawValue: raw ?? "") ?? .cover
    }
}

/// UserDefaults keys for the full-window background image theme. Mirrors the
/// `sidebarAppearance.backgroundImage*` keys parsed from cmux.json and the
/// `@AppStorage` bindings used by the settings GUI.
enum BackgroundImageThemeDefaults {
    static let pathKey = "sidebarBackgroundImagePath"
    static let opacityKey = "sidebarBackgroundImageOpacity"
    static let fitKey = "sidebarBackgroundImageFit"

    static let defaultOpacity = 0.2
    static let defaultFit = BackgroundImageFit.cover
}

/// Loads and caches the decoded `NSImage` for a background-image theme.
///
/// The snapshot carries only the lightweight path/opacity/fit; the window
/// backdrop bridge resolves the heavy `NSImage` here. `image(forPath:)` is the
/// render-hot path (called from `WindowBackdropController.apply` on every
/// focus/selection), so on a cache hit it does **no** file-system work — it
/// returns the already-decoded image straight from the in-memory cache. The
/// only disk read is a one-time decode the first time a given path is applied
/// (a deliberate user action, not a per-focus cost).
///
/// `image(forPath:)` is called synchronously from the nonisolated
/// `WindowBackdropController.apply` (an AppKit window bridge), so the cache
/// cannot be actor-isolated without forcing that hot path to become async.
/// A small lock guards the dictionary; it is held only for in-memory reads and
/// writes, never across the one-time decode, and the rare duplicate decode from
/// a same-path race is harmless (idempotent, one-shot).
enum BackgroundImageThemeStore {
    /// Decoded images keyed by resolved path. Capped to avoid unbounded growth
    /// as users try different custom images in a session.
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var insertionOrder: [String] = []
    private static let maxEntries = 12

    /// Expand a leading `~` to the user's home directory. Intermediate tildes
    /// are left untouched, matching cmux's other path handling.
    static func expandedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "~" {
            return NSHomeDirectory()
        }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + String(trimmed.dropFirst(1))
        }
        return trimmed
    }

    /// Returns the decoded image for `rawPath`. Cache hits touch no file system;
    /// a miss decodes once and caches. Returns nil for empty/missing paths so
    /// callers can treat the theme as inactive.
    static func image(forPath rawPath: String) -> NSImage? {
        let path = expandedPath(rawPath)
        guard !path.isEmpty else { return nil }

        lock.lock()
        let cached = cache[path]
        lock.unlock()
        if let cached {
            return cached
        }

        guard let image = NSImage(contentsOfFile: path) else { return nil }

        lock.lock()
        cache[path] = image
        insertionOrder.append(path)
        if insertionOrder.count > maxEntries {
            let evicted = insertionOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()
        return image
    }

    /// Drops a cached decode so a re-applied path (e.g. a replaced custom image)
    /// is reloaded on next access.
    static func invalidate(path rawPath: String) {
        let path = expandedPath(rawPath)
        lock.lock()
        cache.removeValue(forKey: path)
        insertionOrder.removeAll { $0 == path }
        lock.unlock()
    }
}
