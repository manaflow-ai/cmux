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
    @MainActor public static var current: OverlayMaterial { current(in: .shared) }

    /// The material for this Mac under `reduceTransparency`.
    @MainActor public static func current(in reduceTransparency: ReduceTransparency) -> OverlayMaterial {
        select(liquidGlassAvailable: liquidGlassAvailable, reduceTransparency: reduceTransparency.isEnabled)
    }
}

/// The Reduce Transparency state overlay surfaces read, and the one
/// observer that redraws the live surfaces when it changes. Surfaces
/// register themselves; nothing polls. `shared` follows the system
/// setting; tests inject the state through `override` or their own source.
@MainActor
public final class ReduceTransparency {
    /// This Mac's setting and its change notification.
    public static let shared = ReduceTransparency(
        system: { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
        changes: NSWorkspace.shared.notificationCenter
    )

    /// Pins the state (tests, Debug); nil follows `system`. Changing it
    /// redraws every live surface at once.
    public var override: Bool? {
        didSet { if override != oldValue { refreshSurfaces() } }
    }

    /// Whether overlays draw opaque now.
    public var isEnabled: Bool { override ?? system() }

    private let system: @MainActor () -> Bool
    private let changes: NotificationCenter
    private let surfaces = NSHashTable<OverlaySurfaceView>.weakObjects()
    private var observer: (any NSObjectProtocol)?

    /// `system` reads the setting; `changes` posts
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` when
    /// it may have changed.
    public init(system: @escaping @MainActor () -> Bool, changes: NotificationCenter) {
        self.system = system
        self.changes = changes
    }

    /// Makes `surface` follow this state until it is deallocated.
    func register(_ surface: OverlaySurfaceView) {
        surfaces.add(surface)
        guard observer == nil else { return }
        observer = changes.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Posted on the main thread (NSWorkspace does); delivered inline.
            MainActor.assumeIsolated { self?.refreshSurfaces() }
        }
    }

    private func refreshSurfaces() {
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
