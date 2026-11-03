import AppKit

extension CEFTab: BrowserColorSchemeApplying {
    public func applyColorScheme(_ scheme: BrowserColorScheme) {
        colorScheme = scheme
        CEFColorScheme.apply(scheme, to: self)
    }

    /// Sends the tab's color scheme again: the browser just attached, or the
    /// view's theme changed, and a page following the app has to hear the new
    /// appearance.
    func reapplyColorScheme() { CEFColorScheme.apply(colorScheme, to: self) }
}

/// A Chromium page's `prefers-color-scheme` through DevTools media
/// emulation (`Emulation.setEmulatedMedia`). Chromium draws in its own child
/// window, so the host view's appearance does not reach the page: for
/// `.system` the emulation carries the appearance the rest of the window is
/// in (`ThemeScope` puts windows and views in the theme's appearance), so a
/// page that follows the app is dark in a dark cmux theme like a WebKit tab,
/// whatever macOS itself is set to. The call also carries the page's
/// reduced-motion emulation (`WebDevToolsToggles.emulatedMedia`).
enum CEFColorScheme {
    static func apply(_ scheme: BrowserColorScheme, to tab: CEFTab) {
        // One call carries the color scheme and Developer Tools' reduced motion, so neither clears the other.
        let wanted = value(for: scheme, in: tab.container)
        tab.devToolsModes.colorScheme = wanted
        // A dead renderer hears nothing, and its browser host outlives it, so
        // `browserID` alone would memoize a value no page ever got. Stay unsent
        // until the restarted renderer commits a document and asks again
        // (`.loadStart`); otherwise the memo below suppresses that resend.
        guard let browserID = tab.browserID, !tab.isClosed, tab.state.processExit == nil else {
            tab.sentColorScheme = nil
            return
        }
        // Every tab switch moves the view and asks again; only a change is worth a round trip.
        guard tab.sentColorScheme != wanted else { return }
        // From fork API 29 the scheme is a web preference (no DevTools session, so the tab's renderer
        // stays shareable). Developer Tools' reduced motion still uses emulation, only while it is on.
        if tab.runtime.forkFeatures.rendererPaths, !tab.devToolsModes.isOn(.toggleReducedMotion),
           let setScheme = tab.runtime.shim?.tabSetColorScheme {
            tab.sentColorScheme = setScheme(browserID, wanted == "dark" ? 2 : 1) == 1 ? wanted : nil
            return
        }
        tab.sentColorScheme = wanted
        let runtime = tab.runtime
        let media = tab.devToolsModes.emulatedMedia
        Task { [weak tab] in
            do {
                _ = try await runtime.devTools(browserID, method: media.method, params: media.params)
            } catch {
                // A send that threw or timed out must not stay remembered as
                // sent: the guard above would short-circuit every later
                // `reapplyColorScheme()` and the page would keep the wrong
                // appearance -- light in a dark theme -- for the tab's whole
                // life, since only a renderer exit clears the memo. Forget it
                // unless a newer value has since been sent.
                guard let tab, tab.sentColorScheme == wanted else { return }
                tab.sentColorScheme = nil
                runtime.logger.info("color scheme: \(media.method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The `prefers-color-scheme` value to emulate: the tab's own choice, or
    /// for `.system` the appearance `view` draws in.
    @MainActor static func value(for scheme: BrowserColorScheme, in view: NSView) -> String {
        switch scheme {
        case .light, .dark: scheme.rawValue
        case .system: isDark(view) ? "dark" : "light"
        }
    }

    @MainActor static func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
