public import Foundation

/// DEBUG-only dogfood override for the terminal keyboard dock path.
///
/// Settings > Developer writes the persisted flag through
/// ``MobileDisplaySettings`` and `GhosttySurfaceHostView` reads it once per
/// terminal host, so both packages share this key without a dependency edge.
/// Release builds ignore the stored value entirely: production path selection
/// stays tied to the OS version.
public struct MobileKeyboardDockDebugSetting {
    private init() {}

    /// UserDefaults key forcing the legacy (iOS 27) keyboard dock path on any
    /// OS. Standard defaults resolution also honors a
    /// `-cmux.mobile.debug.forceLegacyKeyboardDock.v1 1` launch argument, which
    /// is how UI tests exercise the same code path the Settings toggle drives.
    public static let forceLegacyDefaultsKey = "cmux.mobile.debug.forceLegacyKeyboardDock.v1"

    /// Whether the stored override forces the legacy keyboard dock path.
    /// - Parameter defaults: The store to read; callers pass `.standard` at
    ///   runtime and a scoped suite in tests.
    /// - Returns: The stored flag in DEBUG builds; always `false` in release.
    public static func forceLegacy(from defaults: UserDefaults) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: forceLegacyDefaultsKey)
        #else
        return false
        #endif
    }
}
