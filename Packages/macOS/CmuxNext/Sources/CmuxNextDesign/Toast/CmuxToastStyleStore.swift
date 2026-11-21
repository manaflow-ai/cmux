public import Foundation

/// The toast style the person picked in the Toast Playground (``CmuxToastStyle``), kept in `defaults` so the
/// pick lasts across launches. Nothing picked (or a style a later build dropped): ``CmuxToastStyle/standard``.
///
/// The shared ``CmuxToastCenter`` keeps one over `UserDefaults.standard` and restyles every toast showing
/// when it changes; views that draw a toast of their own follow it (``follow(_:)``). Tests pass a suite of
/// their own, or nil to keep the pick in memory.
///
/// ```swift
/// let styles = CmuxToastStyleStore(defaults: .standard)
/// styles.pick(.capsule)
/// styles.style // .capsule, also after a relaunch
/// ```
@MainActor
public final class CmuxToastStyleStore {
    /// The defaults key that holds the picked style's raw value.
    public static let key = "cmux.toasts.style"

    private let defaults: UserDefaults?
    /// The picked style.
    public private(set) var style: CmuxToastStyle
    private let followers = NSHashTable<AnyObject>.weakObjects()

    /// - Parameter defaults: Where the pick persists; nil keeps it in memory only.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        style = defaults?.string(forKey: Self.key).flatMap(CmuxToastStyle.init(rawValue:)) ?? .standard
    }

    /// Makes `style` the style of every toast, now and after a relaunch, and tells every follower.
    public func pick(_ style: CmuxToastStyle) {
        guard style != self.style else { return }
        self.style = style
        if style == .standard { defaults?.removeObject(forKey: Self.key) } else { defaults?.set(style.rawValue, forKey: Self.key) }
        for case let follower as any CmuxToastStyleFollowing in followers.allObjects { follower.toastStyleDidChange(style) }
    }

    /// Calls `follower` on every pick from now on, as long as it lives (held weakly).
    public func follow(_ follower: any CmuxToastStyleFollowing) {
        followers.add(follower)
    }
}
