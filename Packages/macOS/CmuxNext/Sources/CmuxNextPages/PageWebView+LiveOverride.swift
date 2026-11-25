import AppKit
import Foundation
import os

// The live web loop (``WebDevOverride``) turned on while this page showed in a Chromium that cannot
// serve it (``PageChromiumHosting/setLivePages(_:)`` false): Chromium shows only the bundled files,
// so the page re-picks its engine and, when ``PageEnginePolicy`` now says WebKit, reopens there at
// once, keeping its route and scroll (``WebDevOverrideWatcher/reloadPages(live:hosting:pages:served:watcher:)``).
extension PageWebView {
    /// Whether the page shows in Chromium or is starting its Chromium page.
    var isOnChromium: Bool { chromiumSession != nil || chromiumStart != nil }

    /// Re-picks the engine with the live loop in force and reopens the page in WebKit when that is
    /// the pick: at the fragment its Chromium page shows (the page's own links move it on from
    /// ``route``), scrolled where it was, and with the keys when it had them. Does nothing for a
    /// page already on WebKit or one the policy keeps in Chromium.
    ///
    /// - Parameters:
    ///   - hosting: The Chromium host the page came from.
    ///   - isCurrent: Whether the reload that asked for the move is still the latest (a later one,
    ///     the loop turned off again, supersedes it).
    func reopenForLiveOverride(hosting: any PageChromiumHosting, isCurrent: () -> Bool = { true }) async {
        guard isOnChromium else { return }
        let decision = PageEnginePolicy(preference: hosting.preference, chromiumAvailable: hosting.isAvailable,
                                        chromiumServes: hosting.serves(descriptor), liveWebOverride: true)
            .decide(for: descriptor, options: engineOptions)
        guard decision.engine == .webKit, let reason = decision.webKitReason else { return }
        let session = chromiumSession
        let shown = session == nil ? nil : await callPageFunction(Self.scrollCaptureScript, timeout: .seconds(1)) as? [String: Any]
        // The page closed, fell back or moved on while its state was read: nothing left to move.
        guard !isClosed, chromiumSession === session, isOnChromium, isCurrent() else { return }
        // `location.hash` is percent-encoded; ``PageDescriptor/url(route:)`` keeps its escapes.
        if let hash = shown?["hash"] as? String, hash.count > 1, hash.hasPrefix("#") { route = hash }
        let hadKeys = session?.page.hasKeys == true || (window?.firstResponder as? NSView).map { $0.isDescendant(of: self) } == true
        fallBackToWebKit(reason, detail: "the live web loop is on and Chromium cannot serve it", level: .info)
        // The keys follow the page to WebKit: the pane's focus model re-applies itself (as when a
        // Chromium page arrives, attachChromium), else the page takes them when Chromium had them.
        if chromiumFocusHost?.focusViewChanged(self) != true, hadKeys { focusPage() }
        guard let spots = shown?["spots"] as? [Any], !spots.isEmpty else { return }
        await waitUntilLoaded()
        guard !isClosed, !isOnChromium else { return }
        _ = await callPageFunction(Self.scrollRestoreScript, arguments: ["spots": spots])
    }

    /// The document's fragment and every scrolled box: `{hash, spots: [{path, top, left}]}`,
    /// `path` the child indexes from the root element (null for the document's own scroller).
    static let scrollCaptureScript = """
        const root = document.scrollingElement || document.documentElement;
        const path = (el) => {
            const out = [];
            for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
                out.unshift(Array.prototype.indexOf.call(n.parentElement.children, n));
            }
            return out;
        };
        const spots = [];
        if (root.scrollTop > 0 || root.scrollLeft > 0) spots.push({ path: null, top: root.scrollTop, left: root.scrollLeft });
        for (const el of document.querySelectorAll('*')) {
            if (el !== root && (el.scrollTop > 0 || el.scrollLeft > 0)) spots.push({ path: path(el), top: el.scrollTop, left: el.scrollLeft });
        }
        return { hash: location.hash, spots };
        """

    /// Scrolls each of `spots` (``scrollCaptureScript``) back, as the document renders: at once, then
    /// on each change of the document's tree or size until all are back or 3 s passed. Returns how
    /// many are back.
    static let scrollRestoreScript = """
        const find = (path) => {
            if (path === null) return document.scrollingElement || document.documentElement;
            let n = document.documentElement;
            for (const i of path) n = n && n.children[i];
            return n || null;
        };
        let pending = spots;
        const apply = () => {
            pending = pending.filter((s) => {
                const el = find(s.path);
                if (!el) return true;
                el.scrollTo({ top: s.top, left: s.left, behavior: 'instant' });
                return Math.abs(el.scrollTop - s.top) > 1 || Math.abs(el.scrollLeft - s.left) > 1;
            });
            return pending.length === 0;
        };
        if (!apply()) {
            await new Promise((resolve) => {
                const done = () => { mutations.disconnect(); sizes.disconnect(); clearTimeout(cap); resolve(); };
                const mutations = new MutationObserver(() => { if (apply()) done(); });
                const sizes = new ResizeObserver(() => { if (apply()) done(); });
                mutations.observe(document.documentElement, { childList: true, subtree: true });
                sizes.observe(document.documentElement);
                const cap = setTimeout(done, 3000);
            });
        }
        return spots.length - pending.length;
        """
}
