public import Foundation

/// The toast style the person picked in the Toast Playground (``CmuxToastStyle``), kept in `defaults` so the
/// pick lasts across launches. Nothing picked (or a style a later build dropped): the style cmux.json names
/// (`notifications.toast.style`, ``configure(_:)``), else ``CmuxToastStyle/standard``.
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
    /// The style picked in the Toast Playground; nil: none.
    private var picked: CmuxToastStyle?
    /// The style cmux.json names (`notifications.toast.style`, a theme hook): the style while nothing is picked.
    public private(set) var configured: CmuxToastStyle = .standard
    /// The picked style, else the configured one.
    public var style: CmuxToastStyle { picked ?? configured }
    private let followers = NSHashTable<AnyObject>.weakObjects()

    /// - Parameter defaults: Where the pick persists; nil keeps it in memory only.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        picked = defaults?.string(forKey: Self.key).flatMap(CmuxToastStyle.init(rawValue:))
    }

    /// Makes `style` the style of every toast, now and after a relaunch, and tells every follower. Picking the
    /// configured style clears the pick, so the toasts follow cmux.json again.
    public func pick(_ style: CmuxToastStyle) {
        guard style != self.style else { return }
        picked = style == configured ? nil : style
        if let picked { defaults?.set(picked.rawValue, forKey: Self.key) } else { defaults?.removeObject(forKey: Self.key) }
        tellFollowers()
    }

    /// Makes `style` the style while nothing is picked (`notifications.toast.style`); followers hear it only
    /// when the style drawn changes.
    public func configure(_ style: CmuxToastStyle) {
        let before = self.style
        configured = style
        if self.style != before { tellFollowers() }
    }

    private func tellFollowers() {
        let style = self.style
        for case let follower as any CmuxToastStyleFollowing in followers.allObjects { follower.toastStyleDidChange(style) }
    }

    /// Calls `follower` on every pick from now on, as long as it lives (held weakly).
    public func follow(_ follower: any CmuxToastStyleFollowing) {
        followers.add(follower)
    }
}
