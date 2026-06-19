import Foundation

/// One-time migration that re-seeds the sidebar appearance defaults to the
/// native-sidebar preset for users who never customized them.
///
/// Early builds shipped a translucent sidebar default (material `sidebar`,
/// blend mode `behindWindow`, follow-window state, tint `#101010` at 0.54
/// opacity, blur 0.79, no corner radius). The product default later became the
/// opaque native-sidebar preset. This migration detects a `UserDefaults`
/// instance still carrying the original shipped values and rewrites the
/// `sidebar*` keys to the native-sidebar preset, so existing users move to the
/// new default exactly as a fresh install would. A user who had changed any of
/// those keys is left untouched.
///
/// The migration is **pure and synchronous** by design and runs once at the
/// very start of launch: it is gated on a stored version under
/// ``versionKey`` and writes that version on completion, so later launches no-op
/// even if the user subsequently dials the values back to the legacy set.
///
/// Wire format is **frozen**. The eight `sidebar*` keys, the version key, the
/// legacy-default sentinels this checks against, and the native-sidebar preset
/// values this writes are all string/`Double` literals kept byte-identical to
/// the values the app's `WindowChromeSidebar*` preset vocabulary produced when
/// this logic lived in `cmuxApp`. They are inlined here as literals (rather than
/// referencing those enums) so the migration stays in this zero-AppKit
/// foundation package without depending upward on the window-chrome UI module.
/// `UserDefaults` is injected so the behavior is fully unit-testable against a
/// scoped suite.
///
/// ```swift
/// SidebarAppearanceDefaultsMigration(defaults: .standard).migrate()
/// ```
public struct SidebarAppearanceDefaultsMigration: Sendable {
    /// `UserDefaults` key holding the applied migration version.
    public static let versionKey = "sidebarAppearanceDefaultsVersion"

    /// The version this migration brings the defaults up to.
    public static let targetVersion = 1

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a migration operating on the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Re-seeds the sidebar appearance defaults to the native-sidebar preset
    /// when the suite still carries the original shipped legacy values, then
    /// records ``targetVersion`` so the migration runs at most once.
    ///
    /// No-ops when the stored ``versionKey`` already meets ``targetVersion``,
    /// and leaves the `sidebar*` keys untouched when any of them differs from
    /// the legacy default set (the user customized the sidebar).
    public func migrate() {
        guard defaults.integer(forKey: Self.versionKey) < Self.targetVersion else { return }

        let material = defaults.string(forKey: "sidebarMaterial") ?? Self.legacyMaterial
        let blendMode = defaults.string(forKey: "sidebarBlendMode") ?? Self.legacyBlendMode
        let state = defaults.string(forKey: "sidebarState") ?? Self.legacyState
        let tintHex = defaults.string(forKey: "sidebarTintHex") ?? Self.legacyTintHex
        let tintOpacity = defaults.object(forKey: "sidebarTintOpacity") as? Double ?? Self.legacyTintOpacity
        let blurOpacity = defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? Self.legacyBlurOpacity
        let cornerRadius = defaults.object(forKey: "sidebarCornerRadius") as? Double ?? Self.legacyCornerRadius

        let usesLegacyDefaults =
            material == Self.legacyMaterial &&
            blendMode == Self.legacyBlendMode &&
            state == Self.legacyState &&
            Self.normalizeHex(tintHex) == Self.legacyTintHexNormalized &&
            Self.approximatelyEqual(tintOpacity, Self.legacyTintOpacity) &&
            Self.approximatelyEqual(blurOpacity, Self.legacyBlurOpacity) &&
            Self.approximatelyEqual(cornerRadius, Self.legacyCornerRadius)

        if usesLegacyDefaults {
            defaults.set(Self.presetRawValue, forKey: "sidebarPreset")
            defaults.set(Self.presetMaterial, forKey: "sidebarMaterial")
            defaults.set(Self.presetBlendMode, forKey: "sidebarBlendMode")
            defaults.set(Self.presetState, forKey: "sidebarState")
            defaults.set(Self.presetTintHex, forKey: "sidebarTintHex")
            defaults.set(Self.presetTintOpacity, forKey: "sidebarTintOpacity")
            defaults.set(Self.presetBlurOpacity, forKey: "sidebarBlurOpacity")
            defaults.set(Self.presetCornerRadius, forKey: "sidebarCornerRadius")
        }

        defaults.set(Self.targetVersion, forKey: Self.versionKey)
    }

    // MARK: - Legacy default sentinels (the original shipped translucent set)

    private static let legacyMaterial = "sidebar"
    private static let legacyBlendMode = "behindWindow"
    private static let legacyState = "followWindow"
    private static let legacyTintHex = "#101010"
    private static let legacyTintHexNormalized = "101010"
    private static let legacyTintOpacity = 0.54
    private static let legacyBlurOpacity = 0.79
    private static let legacyCornerRadius = 0.0

    // MARK: - Native-sidebar preset (the rewrite target)

    private static let presetRawValue = "nativeSidebar"
    private static let presetMaterial = "sidebar"
    private static let presetBlendMode = "withinWindow"
    private static let presetState = "followWindow"
    private static let presetTintHex = "#000000"
    private static let presetTintOpacity = 0.18
    private static let presetBlurOpacity = 1.0
    private static let presetCornerRadius = 0.0

    // MARK: - Pure helpers

    private static func normalizeHex(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
