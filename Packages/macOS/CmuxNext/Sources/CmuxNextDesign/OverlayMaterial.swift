public import AppKit
public import CmuxTheme

/// How an app overlay that floats over content (palette, hover card, find
/// and prompt bars, the tab drag's drop target) is drawn. One decision for
/// every OS and accessibility setting.
public enum OverlayMaterial: Equatable, Sendable {
    /// Real Liquid Glass (`NSGlassEffectView`, macOS 26 and later).
    case liquidGlass
    /// Before Liquid Glass: a behind-window blur (`NSVisualEffectView`)
    /// with a Ghostty-derived tint and a hairline border.
    case vibrancy
    /// Reduce Transparency: an opaque Ghostty-derived fill with a hairline
    /// border, no blur and no glass.
    case opaque

    /// The material for an OS that has (or lacks) Liquid Glass and the
    /// user's Reduce Transparency setting.
    public static func select(liquidGlassAvailable: Bool, reduceTransparency: Bool) -> OverlayMaterial {
        if reduceTransparency { return .opaque }
        return liquidGlassAvailable ? .liquidGlass : .vibrancy
    }

    /// Whether this OS has Liquid Glass (macOS 26 and later). A runtime
    /// check, so the selection stays testable for every OS.
    public static var liquidGlassAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// The material for this Mac now.
    @MainActor public static var current: OverlayMaterial {
        select(liquidGlassAvailable: liquidGlassAvailable, reduceTransparency: ReduceTransparency.isEnabled)
    }
}

/// The Reduce Transparency state every overlay surface reads, and the one
/// observer that redraws live surfaces when it changes. Surfaces register
/// themselves; nothing polls.
@MainActor
public enum ReduceTransparency {
    /// Pins the state (tests, Debug); nil follows the system setting.
    /// Changing it redraws every live surface at once.
    public static var override: Bool? {
        didSet { if override != oldValue { refreshSurfaces() } }
    }

    /// Whether overlays draw opaque now.
    public static var isEnabled: Bool {
        override ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private static let surfaces = NSHashTable<OverlaySurfaceView>.weakObjects()
    private static var observer: (any NSObjectProtocol)?

    /// Makes `surface` follow this state until it is deallocated.
    static func register(_ surface: OverlaySurfaceView) {
        surfaces.add(surface)
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { refreshSurfaces() }
        }
    }

    private static func refreshSurfaces() {
        for surface in surfaces.allObjects { surface.refreshMaterial() }
    }
}

extension ThemeTokens {
    /// The Reduce Transparency overlay fill: the window background moved
    /// `lift` toward the primary text, both opaque.
    nonisolated public func opaqueOverlayFill(lift: Double) -> ThemeRGB {
        windowBackground.withAlpha(1).mixed(toward: textPrimary.withAlpha(1), lift)
    }
}
