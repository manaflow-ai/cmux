public import Foundation

/// Which Screenshots tabs the person has unlocked with Show Screenshots, by tab key, and whether the person
/// clicked it in an earlier launch.
///
/// A tab's page is made again after a hibernation wake or an engine switch; an unlocked tab lists at once then,
/// with no second click. The first click is remembered across launches in the injected `defaults`, so a page
/// of a later launch lists as soon as it is on screen, with no card (``wire(_:key:onShow:)``). Until a page
/// lists, no folder is detected, read or watched (macOS guards ~/Desktop: LAUNCH-NO-TCC-PROMPTS). When no
/// folder can be read (access was taken back), the remembered click is forgotten and the card shows again.
///
/// ```swift
/// let gate = ScreenshotsGate(defaults: .standard) // the app; a test passes UserDefaults(suiteName:)
/// gate.wire(page.view, key: key) { service.unlock(key) }
/// ```
@MainActor
public final class ScreenshotsGate {
    private var unlocked: Set<String> = []
    private let defaults: UserDefaults
    private static let accessKey = "screenshots.showScreenshotsClicked"

    /// Makes a gate with no tab unlocked in this launch.
    ///
    /// - Parameter defaults: where the person's first click is remembered across launches.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether the person clicked Show Screenshots in this or an earlier launch, and no read failed since.
    public var remembersAccess: Bool { defaults.bool(forKey: Self.accessKey) }

    /// Whether the person unlocked the tab `key` in this launch.
    public func isUnlocked(_ key: String) -> Bool { unlocked.contains(key) }

    /// Whether any tab is unlocked: only then may the folders be detected.
    public var mayDetect: Bool { !unlocked.isEmpty }

    /// The person clicked Show Screenshots in the tab `key`, or its page listed from a remembered click.
    public func unlock(_ key: String) {
        unlocked.insert(key)
        defaults.set(true, forKey: Self.accessKey)
    }

    /// No folder could be read: the next page shows the card again.
    public func forgetAccess() {
        defaults.removeObject(forKey: Self.accessKey)
    }

    /// A model for the tab `key`'s page: listing at once when the person unlocked the tab in this launch.
    public func model(for key: String) -> ScreenshotsModel { ScreenshotsModel(listsAtOnce: isUnlocked(key)) }

    /// Connects the tab `key`'s view: it lists once on screen when the click is remembered, tells `onShow` when
    /// it starts listing (a click or a remembered one), and forgets the click when no folder can be read.
    ///
    /// - Parameters:
    ///   - view: the page's view.
    ///   - key: the tab key.
    ///   - onShow: runs when the page starts listing; the app unlocks the tab and finds the folders.
    public func wire(_ view: ScreenshotsView, key: String, onShow: @escaping () -> Void) {
        view.onShowScreenshots = onShow
        view.onAccessMissing = { [weak self] in self?.forgetAccess() }
        view.startsWhenShown = remembersAccess && !isUnlocked(key)
    }
}
