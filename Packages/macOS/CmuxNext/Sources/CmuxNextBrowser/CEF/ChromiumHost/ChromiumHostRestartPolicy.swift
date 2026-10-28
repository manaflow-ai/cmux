/// Whether a Chromium host that ended starts again with its page.
///
/// The rule is the app's own safe-restart rule
/// (plans/cmux-next/browser-isolation.md, "Safe restart rule"): a host that
/// ran at least ``quickEnd`` restarts and reloads its page; one that ends
/// again sooner stays ended until the person reloads, so a page that crashes
/// its browser process at once never loops.
nonisolated struct ChromiumHostRestartPolicy: Sendable {
    /// The app's safe-restart window (browser-isolation.md).
    static let standardQuickEnd: Duration = .seconds(60)

    var quickEnd: Duration = Self.standardQuickEnd

    /// - Parameters:
    ///   - ranFor: how long the host ran before it ended.
    ///   - isFirstStart: the host that ended was the first one of the page (not a restart).
    func restarts(ranFor: Duration, isFirstStart: Bool) -> Bool {
        isFirstStart || ranFor >= quickEnd
    }
}
