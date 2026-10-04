import AppKit

/// Chromium window requests: the one decision (`CEFWindowPolicy`) applied,
/// its log (`debug.cef` `window_requests`) and the link click state the
/// decision reads (`CEFLinkClickTracker`).
@MainActor
final class CEFWindowRequests {
    private weak var runtime: CEFRuntime?
    var log = CEFWindowRequestLog()
    /// Link click mapping, last click and pending popup URLs.
    let linkClicks = CEFLinkClickTracker()

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// Where a Chromium window request goes (`CEFWindowPolicy`), applied.
    func handle(_ reported: CEFWindowRequest) -> Int32 {
        guard let runtime else { return 0 }
        let request = resolvedStore(of: reported, in: runtime)
        let decision = CEFWindowPolicy.decide(request, candidates: windowCandidates(for: request, in: runtime),
                                              links: linkClicks.context())
        log.record(request, decision)
        runtime.logger.notice("Chromium window request kind=\(request.kind.rawValue) disposition=\(request.disposition.rawValue) source=\(request.sourceBrowser) -> \(String(describing: decision), privacy: .public)")
        switch decision {
        case .insert(let anchor, let disposition):
            if let window = runtime.shim?.tabWindowID(anchor), window != 0 {
                runtime.placements.record(window: window, CEFPlacement(disposition: disposition, bounds: request.bounds))
            }
            return anchor
        case .openInNewTab(let url, let disposition):
            if let url = URL(string: url) {
                // Not from inside Chromium's navigation: the App creates a tab.
                let profile = runtime.storage.profile(forPath: request.profilePath)
                Task { @MainActor [weak runtime] in runtime?.openURLWithoutWindow?(url, disposition, profile) }
            }
            return 0
        case .loadInSource(let url):
            // Not from inside Chromium's navigation.
            let source = runtime.tabsByBrowser[request.sourceBrowser]
            if let url = URL(string: url) { Task { @MainActor in source?.load(url) } }
            return 0
        case .openOffTheRecord(let url):
            let source = runtime.tabsByBrowser[request.sourceBrowser]
            // Not from inside Chromium's navigation: the App opens a window.
            Task { @MainActor [weak runtime] in runtime?.openOffTheRecord?(url.isEmpty ? nil : URL(string: url), source) }
            return 0
        case .refuse(let refusal):
            runtime.refused(refusal, source: request.sourceBrowser)
            return 0
        }
    }

    /// The request with the store cmux knows it came from: the source tab's
    /// store (an incognito window's in-memory context has no directory of
    /// its own; Chromium names its parent's), else the reported directory,
    /// which is persistent only when it is a cmux profile directory.
    func resolvedStore(of reported: CEFWindowRequest, in runtime: CEFRuntime) -> CEFWindowRequest {
        var request = reported
        if let host = runtime.tabsByBrowser[reported.sourceBrowser]?.host {
            request.profilePath = runtime.storeKey(of: host.key)
            request.persistentProfile = !host.key.offTheRecord
        } else {
            request.persistentProfile = runtime.storage.isPersistentProfilePath(reported.profilePath)
        }
        return request
    }

    func windowCandidates(for request: CEFWindowRequest, in runtime: CEFRuntime) -> [CEFWindowCandidate] {
        // A popup panel holds only its popup: what a popup page opens goes
        // to the window of the pane that opened the popup.
        var sourceHost = runtime.tabsByBrowser[request.sourceBrowser]?.host
        if let popup = sourceHost, popup.isPopupHost {
            sourceHost = popup.tabs.lazy.compactMap(\.popupOpenerHost).first
        }
        return runtime.hosts.values.compactMap { host in
            guard host.isLive, !host.isPopupHost, let anchor = host.anchorBrowser else { return nil }
            return CEFWindowCandidate(
                anchor: anchor,
                profilePath: runtime.storeKey(of: host.key),
                holdsSource: host === sourceHost,
                lastShown: host === runtime.lastShownHost,
                visible: host.hostView.window != nil && !host.hostView.isHiddenOrHasHiddenAncestor
            )
        }
        .sorted { $0.anchor < $1.anchor }
    }

    /// The shown Chromium pages a click can land on (`CEFLinkClicks.browser`).
    func clickTargets() -> [CEFClickTarget] {
        guard let runtime else { return [] }
        return runtime.hosts.values.compactMap { host in
            let view = host.hostView
            guard let window = view.window, !view.isHiddenOrHasHiddenAncestor, let browser = host.visibleTab?.browserID else { return nil }
            let screen: (CGRect) -> CGRect = { window.convertToScreen(view.convert($0, to: nil)) }
            return CEFClickTarget(browser: browser, hostWindow: ObjectIdentifier(window), frame: screen(view.bounds),
                                  occlusions: view.occlusionRects.map(screen))
        }
    }
}
