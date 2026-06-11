import AppKit

/// Forces overlay (auto-fading) scrollers across all of cmux's AppKit and
/// WKWebView scroll views by overriding a system-wide "Show scroll bars:
/// Always" (legacy) preference for cmux's process only.
///
/// In legacy-scroller environments — a mouse connected, or System Settings →
/// Appearance → Show scroll bars → Always (`defaults write -g
/// AppleShowScrollBars Always`) — macOS draws persistent, always-visible
/// scrollbars in every scroll view app-wide, including the page content of
/// `WKWebView`. That reserves a permanent bright track over browser panes and
/// other cmux chrome, which is the persistent-scrollbar symptom reported in
/// https://github.com/manaflow-ai/cmux/issues/3241.
///
/// AppKit resolves `NSScroller.preferredScrollerStyle` from the
/// `AppleShowScrollBars` default. Writing `WhenScrolling` into cmux's *own*
/// application defaults domain takes precedence over `NSGlobalDomain` for this
/// process only, so every cmux scroll view (the sidebar list, browser-pane web
/// content, settings panes, the file explorer) adopts the overlay style while
/// the user's system-wide preference is left untouched for every other app.
///
/// This is the same intent already applied surface-by-surface elsewhere
/// (terminals, the sidebar, text inputs all force `scrollerStyle = .overlay`);
/// this policy makes overlay the process default so AppKit-created scrollers
/// that cmux does not directly own — most importantly `WKWebView` page
/// scrollers — match instead of inheriting the legacy style.
///
/// It composes with `SidebarScrollViewConfigurator`: that type still forces
/// `.overlay` directly on the sidebar scroll view and tolerates no same-value
/// rewrites; this policy only changes the *default* AppKit reads when it
/// creates a scroller, so the two never fight. To avoid a redundant write
/// (which posts `UserDefaults.didChangeNotification` and can nudge AppKit to
/// re-evaluate scroller style mid-fade), the override is written only when
/// cmux's *application domain* does not already hold `WhenScrolling`.
///
/// Caveat: because the registration domain ranks *below* `NSGlobalDomain`, a
/// non-persistent `register(defaults:)` cannot beat a user's `Always`
/// preference — the override must live in the persistent application domain.
/// That value therefore outlives this code: if this policy is ever removed or
/// replaced with a user-facing opt-out, that change must also delete the
/// `AppleShowScrollBars` key from cmux's application domain (e.g. a one-shot
/// `defaults.removeObject(forKey:)` migration) so stale installs stop forcing
/// overlay. Accessibility note: this overrides a deliberate system-wide
/// "Always" choice for cmux only; it intentionally matches the no-opt-out
/// overlay forcing the terminal/sidebar/text-input surfaces already apply.
enum AppScrollerStylePolicy {
    /// `AppleShowScrollBars` selects overlay vs. legacy scrollers app-wide.
    static let scrollBarsDefaultsKey = "AppleShowScrollBars"

    /// The value AppKit maps to the modern overlay (auto-fading) scroller style.
    static let overlayValue = "WhenScrolling"

    /// Registers the per-app overlay-scroller override.
    ///
    /// Call this as early as possible in app launch — **before any
    /// AppKit-adjacent work** (appearance, language, scroll-view creation).
    /// AppKit resolves `NSScroller.preferredScrollerStyle` lazily and caches
    /// it; it only re-resolves when System Settings posts the distributed
    /// `AppleShowScrollBarsSettingChanged` notification. A local
    /// `UserDefaults.set` does **not** post that notification, so on the first
    /// launch after this ships (before the value is persisted) the override
    /// only takes effect if nothing has queried `preferredScrollerStyle` yet.
    /// Running first makes the contract self-enforcing rather than relying on
    /// the ordering of unrelated `init` steps.
    static func applyAtLaunch(
        defaults: UserDefaults = .standard,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        // Decide by inspecting cmux's *application domain specifically*, not the
        // cross-domain `string(forKey:)` resolution. If the user's global
        // preference already resolves to `WhenScrolling`, a cross-domain check
        // would skip the write and leave cmux with no app-domain override — and
        // a later system switch to "Always" (which posts the distributed
        // settings-changed notification) would then re-resolve AppKit to legacy
        // scrollers for the rest of the session, reintroducing #3241 until the
        // next launch. Persisting to the app domain whenever it is absent makes
        // the override deterministic while still avoiding redundant writes.
        let appDomainValue = defaults.persistentDomain(forName: bundleIdentifier)?[scrollBarsDefaultsKey] as? String
        if appDomainValue != overlayValue {
            defaults.set(overlayValue, forKey: scrollBarsDefaultsKey)
        }
    }
}
