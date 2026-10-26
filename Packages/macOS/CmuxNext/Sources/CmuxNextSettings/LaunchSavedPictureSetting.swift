/// `launch.savedPicture` in cmux-next.json: whether a quit saves one picture of each window and the next launch
/// shows it as that window's first frame until the live window is built under it (p08-startup 3C,
/// `WindowPictureStore`). On by default; nothing is saved or shown while the `savedWindowPicture` feature is off.
/// Off, the saved pictures are deleted at once (`WindowPictureStore.followSavedPicture(_:on:)`) and the next launch shows none. Agents may not change it
/// (`AgentRefusal.privacy`): the pictures hold terminal text and pages.
///
/// Read from the snapshot's document, not stored: a value that is not `false` is on.
public nonisolated struct LaunchSavedPictureSetting: Sendable {
    /// The cmux-next.json key path.
    public static let path = ["launch", "savedPicture"]
    /// On: the person sees their windows at once, as Chrome on Android shows a restored tab's capture
    /// (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java).
    public static let defaultValue = true

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: `false` only for a literal `false`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.path)?.boolValue ?? Self.defaultValue
    }
}

extension CmuxConfigSnapshot {
    /// `launch.savedPicture` (``LaunchSavedPictureSetting``).
    public var savedPicture: Bool { LaunchSavedPictureSetting().value(in: root) }
}
