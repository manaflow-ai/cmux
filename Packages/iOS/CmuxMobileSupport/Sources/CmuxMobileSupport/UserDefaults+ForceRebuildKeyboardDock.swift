public import Foundation

/// DEBUG-only dogfood override for the terminal keyboard dock path.
///
/// Settings > Developer writes the persisted flag through
/// `MobileDisplaySettings` and `GhosttySurfaceHostView` reads it once per
/// terminal host, so both packages share this key without a dependency edge.
/// Release builds ignore the stored value entirely: production path selection
/// is the legacy default plus the remote `ios-keyboard-dock-rebuild-revert`
/// kill switch.
extension UserDefaults {
    /// UserDefaults key forcing the rebuilt (single-constraint) keyboard dock
    /// path on iOS 26 and earlier; iOS 27+ ignores it. Standard defaults
    /// resolution also honors a
    /// `-cmux.mobile.debug.forceRebuildKeyboardDock.v1 1` launch argument,
    /// which is how UI tests exercise the same code path the Settings toggle
    /// drives.
    public static let cmuxForceRebuildKeyboardDockKey =
        "cmux.mobile.debug.forceRebuildKeyboardDock.v1"

    /// Whether the stored override forces the rebuilt keyboard dock path.
    /// The stored flag in DEBUG builds; always `false` in release.
    public var cmuxForceRebuildKeyboardDock: Bool {
        #if DEBUG
        return bool(forKey: Self.cmuxForceRebuildKeyboardDockKey)
        #else
        return false
        #endif
    }
}
