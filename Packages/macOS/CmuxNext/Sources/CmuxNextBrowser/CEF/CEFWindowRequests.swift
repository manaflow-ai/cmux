import AppKit

/// Chromium window requests: the one decision (`CEFWindowPolicy`) applied,
/// its log (`debug.cef` `window_requests`) and the link click state the
/// decision reads (`CEFLinkClickTracker`).
///
/// In process Chromium asks cmux inside its navigation (`cefWindowRequestCallback`). The Chromium Host
/// asks no one (task 031 of plans/cmux-next/chrome-parity/p01-process.md): cmux pushes what the decision
/// reads (``CEFWindowRequestPolicy``) whenever it changes, the host's shim decides by the same rule
/// inside the navigation, and cmux applies the result it reports (``hostDecided(_:)``).
@MainActor
final class CEFWindowRequests {
    private weak var runtime: CEFRuntime?
    var log = CEFWindowRequestLog()
    /// Link click mapping, last click and pending popup URLs.
    let linkClicks = CEFLinkClickTracker()
    /// Host mode: the policy last pushed (nil before the first), and whether a push waits for the end
    /// of this turn.
    private(set) var pushedPolicy: CEFWindowRequestPolicy?
    private var pushesPolicy = false
    private var policyPushPending = false
    /// Runs a block at the end of this run-loop turn; tests run it when they choose.
    var endOfTurn: CEFLayerHosting.Scheduler = { CEFLayerHosting.atEndOfTurn($0) }

    init(runtime: CEFRuntime) {
        self.runtime = runtime
        // A click can decide the next request: it goes to the host in the turn it lands.
        linkClicks.onChange = { [weak self] in self?.pushLinks() }
    }

    /// In process cmux's handler decides inside Chromium's navigation. In host mode no handler is
    /// installed (the host would have to wait on cmux inside its navigation): cmux pushes its policy,
    /// first at the end of this turn, after `cmux_shim_initialize` was sent.
    func install(on shim: CEFShimLibrary, hostMode: Bool) {
        // SAFETY: a C function of `cmux_shim_window_request_fn`; its context is the runtime's token
        // (`cmux_shim_initialize`'s), which CEFRuntime.from resolves in the registry.
        unsafe shim.setWindowRequestHandler(hostMode ? nil : cefWindowRequestCallback)
        pushesPolicy = hostMode
        policyMayHaveChanged()
    }

    /// Where a Chromium window request goes (`CEFWindowPolicy`), applied. In process only: the fork
    /// asks inside its navigation and takes the returned anchor.
    func handle(_ reported: CEFWindowRequest) -> Int32 {
        guard let runtime else { return 0 }
        let request = resolvedStore(of: reported, in: runtime)
        let decision = CEFWindowPolicy.decide(request, candidates: windowCandidates(for: request, in: runtime),
                                              links: linkClicks.context())
        let window = decision.anchor.flatMap { runtime.shim?.tabWindowID($0) } ?? 0
        apply(request, decision, window: window, tab: 0, in: runtime)
        return decision.anchor ?? 0
    }

    /// What the Chromium Host decided inside its navigation with the pushed policy, applied as
    /// ``handle(_:)`` applies cmux's own decision. An insert's tab arrives in its own AFTER_CREATED,
    /// after this result, named by the id the host minted for it (``CEFWindowRequestResult/tab``), and
    /// cmux adopts it under that id with the placement recorded here.
    func hostDecided(_ result: CEFWindowRequestResult) {
        guard let runtime else { return }
        // A minted id that already names a tab is not a new tab's: the placement goes by window.
        let tab = runtime.tabsByBrowser[result.tab] == nil ? result.tab : 0
        apply(result.request, result.decision, window: result.window, tab: tab, in: runtime)
    }

    private func apply(_ request: CEFWindowRequest, _ decision: CEFWindowDecision, window: Int32, tab: Int32,
                       in runtime: CEFRuntime) {
        log.record(request, decision, tab: tab)
        runtime.logger.notice("Chromium window request kind=\(request.kind.rawValue) disposition=\(request.disposition.rawValue) source=\(request.sourceBrowser) -> \(String(describing: decision), privacy: .public) tab=\(tab)")
        switch decision {
        case .insert(_, let disposition):
            let placement = CEFPlacement(disposition: disposition, bounds: request.bounds)
            if tab != 0 {
                runtime.placements.record(tab: tab, placement)
            } else if window != 0 {
                runtime.placements.record(window: window, placement)
            }
        case .openInNewTab(let url, let disposition):
            if let url = URL(string: url) {
                // Not from inside Chromium's navigation: the App creates a tab.
                let profile = runtime.storage.profile(forPath: request.profilePath)
                Task { @MainActor [weak runtime] in runtime?.openURLWithoutWindow?(url, disposition, profile) }
            }
        case .loadInSource(let url):
            // Not from inside Chromium's navigation.
            let source = runtime.tabsByBrowser[request.sourceBrowser]
            if let url = URL(string: url) { Task { @MainActor in source?.load(url) } }
        case .downloadInSource(let url):
            // Not from inside Chromium's navigation.
            Task { @MainActor [weak runtime] in _ = runtime?.downloads.download(url, browser: request.sourceBrowser) }
        case .openOffTheRecord(let url):
            let source = runtime.tabsByBrowser[request.sourceBrowser]
            // Not from inside Chromium's navigation: the App opens a window.
            Task { @MainActor [weak runtime] in runtime?.openOffTheRecord?(url.isEmpty ? nil : URL(string: url), source) }
        case .refuse(let refusal):
            runtime.refused(refusal, source: request.sourceBrowser)
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
            // The spare window (CEFSpareWindow) is no pane's: never a target.
            guard host.isLive, !host.isPopupHost, !host.isSpare, let anchor = host.anchorBrowser else { return nil }
            return CEFWindowCandidate(
                anchor: anchor,
                profilePath: runtime.storeKey(of: host.key),
                holdsSource: host === sourceHost,
                lastShown: host === runtime.lastShownHost,
                visible: Self.isVisible(host)
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

    private static func isVisible(_ host: CEFPaneHost) -> Bool {
        host.hostView.window != nil && !host.hostView.isHiddenOrHasHiddenAncestor
    }
}

extension CEFWindowRequests {
    /// Something the pushed policy reads changed (a pane window, its tabs, the last shown pane, its
    /// visibility, the link mapping): one push at the end of this turn, and only when the policy differs.
    func policyMayHaveChanged() {
        guard pushesPolicy, !policyPushPending else { return }
        policyPushPending = true
        endOfTurn { [weak self] in self?.pushPolicy() }
    }

    /// Pushes the current policy to the Chromium Host when it differs from the last one pushed.
    func pushPolicy() {
        policyPushPending = false
        guard pushesPolicy, let runtime else { return }
        push(currentPolicy(in: runtime))
    }

    /// A click or a mapping change goes to the host at once, with the windows last pushed: a change
    /// to those is already queued for the end of this turn (``policyMayHaveChanged()``).
    private func pushLinks() {
        guard pushesPolicy, var policy = pushedPolicy else { return pushPolicy() }
        policy.clicks = CEFWindowRequestPolicy.clicks(of: linkClicks.context())
        policy.mapping = linkClicks.mapping
        push(policy)
    }

    private func push(_ policy: CEFWindowRequestPolicy) {
        guard let shim = runtime?.shim, policy != pushedPolicy else { return }
        pushedPolicy = policy
        let actions = policy.actionCodes
        policy.withRows { windows, windowCount, clicks, clickCount in
            policy.profileRoot.withCString { root in
                shim.setWindowRequestPolicy(windows, windowCount, clicks, clickCount, root,
                                            actions[0], actions[1], actions[2], actions[3], actions[4])
            }
        }
    }

    /// What ``CEFWindowPolicy/decide(_:candidates:links:)`` reads, for every request at once: each live
    /// pane window by its anchor (a popup panel names its opener's pane; the spare is no pane's), the
    /// clicks that can still decide a request, the profile root and the link mapping.
    func currentPolicy(in runtime: CEFRuntime) -> CEFWindowRequestPolicy {
        let windows: [CEFWindowRequestPolicy.Window] = runtime.hosts.values.compactMap { host in
            guard host.isLive, !host.isSpare, let anchor = host.anchorBrowser else { return nil }
            let opener = host.isPopupHost ? host.tabs.lazy.compactMap(\.popupOpenerHost).first?.anchorBrowser : nil
            return CEFWindowRequestPolicy.Window(
                anchor: anchor, opener: opener ?? 0, store: runtime.storeKey(of: host.key), candidate: !host.isPopupHost,
                lastShown: host === runtime.lastShownHost, visible: Self.isVisible(host), offTheRecord: host.key.offTheRecord
            )
        }
        return CEFWindowRequestPolicy(
            windows: windows.sorted { $0.anchor < $1.anchor },
            clicks: CEFWindowRequestPolicy.clicks(of: linkClicks.context()),
            profileRoot: CEFRuntime.normalizedPath(runtime.storage.root.path),
            mapping: linkClicks.mapping
        )
    }
}
