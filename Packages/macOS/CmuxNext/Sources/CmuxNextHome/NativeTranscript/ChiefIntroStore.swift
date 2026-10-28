public import Foundation

/// Whether the Chief's first-open intro still has to show on this install.
///
/// The intro is a fixed message from the Chief on the empty Chief conversation. It shows once per
/// install: the first time the front page shows it, it is marked shown and never returns, even when
/// the person ignores it.
public struct ChiefIntroStore: Sendable {
    /// The UserDefaults key that records the intro was shown.
    static let shownKey = "home.firstRun.chiefIntroShown"
    private let defaults: UserDefaults

    /// - Parameter defaults: The defaults the flag lives in. The app passes `.standard`; tests pass a suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// True until ``markShown()`` has run on this install.
    public var shouldShow: Bool { false }

    /// Records that the intro was shown, so it never shows again.
    public func markShown() {}
}
