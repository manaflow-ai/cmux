import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWebUpdates
import Foundation
#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextPages
import CmuxNextSidebar
import WebKit
#endif

// `updates.status`: the updater's state (channel, feed, Sparkle phase,
// automatic-check settings, last probe). `updates.check`: a read-only probe
// of the build's real feed; answers with the typed result (or `pending`
// when the feed is slower than the control deadline), never installs.
// `updates.web.*`: web updates (CmuxNextWebUpdates).
extension AppControl {
    func registerUpdateMethods(_ updater: UpdaterService, services appServices: AppServices) {
        service?.router.register([
            .mainActor("updates.status") { _ in .value(Self.json(updater.status, log: updater.log.recent)) },
            // `updates.highlights {last?}`: the staged update's top changes (the
            // UpdateHighlights contract, cx-ncc.45.5), null while nothing is
            // staged; `last: true` reads the update this launch completed.
            .mainActor("updates.highlights") { call in
                let last = call.params["last"]?.boolValue == true
                guard let highlights = last ? updater.lastUpdateHighlights : updater.stagedHighlights,
                      let data = try? JSONEncoder().encode(highlights),
                      let value = try? JSONValue.parse(data) else { return .value(.null) }
                return .value(value)
            },
            // `{build?, check?}`: rolls back to a kept build, or with check
            // only reports whether it would. Both daemons' stores count: the
            // app's and the Chief conversation owner's.
            .mainActor("updates.rollback") { call in
                let build = call.params["build"]?.stringValue
                let check = call.params["check"]?.boolValue == true
                let stateDirectories = appServices.environment.daemonStateDirectories
                return .followUp {
                    do {
                        let kept = try await UpdateDropBack(updater).run(to: build, checkOnly: check, stateDirectories: stateDirectories)
                        return check ? .object(["allowed": true, "build": .string(kept.build)]) : .object(["rolled_back_to": .string(kept.build)])
                    } catch let refusal as RollbackRefusal {
                        if check { return .object(["allowed": false, "reason": .string(refusal.message)]) }
                        throw ControlError(code: "rollback_refused", message: refusal.message)
                    }
                }
            },
            .mainActor("updates.check") { call in
                let probe = updater.probe()
                // Answer inside the 2 s control deadline. A slower feed leaves
                // the probe running: `pending: true`, then read `updates.status`.
                let answerBy = call.deadline - .milliseconds(150)
                return .followUp {
                    let outcome: (done: Bool, failure: String?)
                    do {
                        outcome = (true, try await ControlDeadline.shared.run(method: call.method, deadline: answerBy) { await probe.value })
                    } catch {
                        outcome = (false, nil)
                    }
                    return await MainActor.run {
                        guard case .object(var fields) = Self.json(updater.status, log: []) else { return .null }
                        fields["pending"] = .bool(!outcome.done)
                        fields["ok"] = outcome.done ? .bool(outcome.failure == nil) : .null
                        if let failure = outcome.failure { fields["error"] = .string(failure) }
                        return .object(fields)
                    }
                }
            },
        ] + WebUpdates.shared.controlMethods)
        // DEV and NIGHTLY only: a test appcast for every check (signatures
        // still required). `{url: null}` returns to the real feed.
        if updater.identity.track == .nightly || updater.identity.track == .development {
            service?.router.register([
                .mainActor("updates.test_feed") { call in
                    do {
                        try updater.useTestFeed(call.params["url"]?.stringValue, pinned: call.params["pinned"]?.boolValue == true)
                    } catch {
                        throw ControlError.invalidParams(String(describing: error))
                    }
                    return .value(Self.json(updater.status, log: []))
                },
                .mainActor("debug.updater") { [weak services = appServices] call in
                    guard let services else { throw ControlError.invalidParams("debug.updater: the app is shutting down") }
                    return .value(try DebugUpdater.run(call.params, services))
                },
            ])
        }
        #if DEBUG
        service?.router.register([
            // `debug.update_surfaces {action}`: for proofs, on the active window's
            // sidebar. "show-popover" (default) opens the staged-update highlights
            // popover (the React surface); "state" reads which update pages the
            // sidebar holds and the web views under it; "dismiss-updated" runs
            // the Updated card's x (cx-asynu). "sidebar-width" {width} sets the
            // active window's sidebar width (narrow-sidebar shots; answers the
            // previous width, to restore it); "open-changes"
            // runs the staged card's "See all changes" (its intent) and
            // "open-whats-new" the Updated card's "See What's New" (cx-7rone).
            .mainActor("debug.update_surfaces") { [weak services = appServices] call in
                guard let services, let sidebar = services.windows.active?.sidebar.container.sidebarView else {
                    throw ControlError.invalidParams("debug.update_surfaces: no active window")
                }
                switch call.params["action"]?.stringValue ?? "show-popover" {
                case "show-popover":
                    return .value(.object(sidebar.debugShowUpdateHighlights().mapValues { JSONValue.string($0) }))
                case "state":
                    var state = sidebar.debugUpdateSurfaceState().mapValues { JSONValue.string($0) }
                    state["sidebarWebViews"] = .number(Double(Self.webViewCount(in: sidebar)))
                    // What the window shows (cx-cmge7 proofs): its top page, else the internal
                    // page of the focused pane's selected tab ("" for none).
                    let window = services.windows.active
                    state["topPage"] = .string(window?.shownTopPage?.rawValue ?? "")
                    state["holdsVisiblePageTab"] = .bool(window?.holdsVisiblePageTab ?? false)
                    let pane = window?.content.flatMap { $0.focusedPane ?? $0.panes.values.first }
                    let selected = pane?.stripModel.selectedID?.rawValue
                    state["selectedPage"] = .string(selected.flatMap { services.pages.page(ofTab: $0)?.rawValue
                        ?? pane?.tab(StripTabID($0))?.page } ?? "")
                    // The Updated card's page in window points from the top-left (debug.mouse's points).
                    if let page = sidebar.debugUpdatedPageView, let pageWindow = page.window {
                        let frame = page.convert(page.bounds, to: nil)
                        let top = InputJournal.topLeftPoint(NSPoint(x: frame.minX, y: frame.maxY), in: pageWindow, relativeTo: pageWindow)
                        state["updatedFrame"] = .array([top.x, top.y, frame.width, frame.height].map { .number(Double($0)) })
                        // Page CSS px times this are view points.
                        state["updatedZoom"] = .number((page as? PageWebView)?.debugPageZoom ?? 1)
                    }
                    if let close = sidebar.debugUpdatedCloseButton, let closeWindow = close.window {
                        let frame = close.convert(close.bounds, to: nil)
                        let top = InputJournal.topLeftPoint(NSPoint(x: frame.minX, y: frame.maxY), in: closeWindow, relativeTo: closeWindow)
                        state["updatedCloseFrame"] = .array([top.x, top.y, frame.width, frame.height].map { .number(Double($0)) })
                    }
                    return .value(.object(state))
                case "hit":
                    // Which view a click at `x`,`y` (window points from the top-left) reaches: the
                    // window's own hit test, as a real click takes it (the Updated card's x proofs).
                    guard let window = services.windows.active?.window, let root = window.contentView?.superview ?? window.contentView,
                          let x = call.params["x"]?.doubleValue, let y = call.params["y"]?.doubleValue else {
                        throw ControlError.invalidParams("debug.update_surfaces: hit needs x and y")
                    }
                    let height = window.contentView?.bounds.height ?? window.frame.height
                    let hit = root.hitTest(root.convert(NSPoint(x: x, y: height - y), from: nil))
                    var chain: [JSONValue] = []
                    var view = hit
                    while let current = view, chain.count < 14 {
                        chain.append(.string(String(describing: type(of: current))))
                        view = current.superview
                    }
                    let inPage = sidebar.debugUpdatedPageView.map { hit?.isDescendant(of: $0) ?? false } ?? false
                    let onClose = sidebar.debugUpdatedCloseButton.map { hit?.isDescendant(of: $0) ?? false } ?? false
                    let firstMouse = hit?.acceptsFirstMouse(for: nil) ?? false
                    return .value(.object(["chain": .array(chain), "inUpdatedPage": .bool(inPage), "onUpdatedClose": .bool(onClose),
                                           "acceptsFirstMouse": .bool(firstMouse)]))
                case "dismiss-updated":
                    services.updater.whatsNew.dismissUpdated()
                    return .value(.null)
                case "sidebar-width":
                    guard let width = call.params["width"]?.doubleValue, width > 0 else {
                        throw ControlError.invalidParams("debug.update_surfaces: sidebar-width needs width")
                    }
                    let previous = Double(sidebar.bounds.width)
                    services.windows.active?.sidebar.restore(width: width, hidden: false)
                    return .value(.object(["previous": .number(previous), "width": .number(width)]))
                case "open-changes":
                    SidebarCardFeed.handle(.openUpdateChanges, services: services)
                    return .value(.null)
                case "open-whats-new":
                    return .value(.bool(services.updater.openWhatsNewForLastUpdate()))
                case let action:
                    throw ControlError.invalidParams("debug.update_surfaces: unknown action \(action)")
                }
            },
            .mainActor("debug.update_indicator") { call in
                updater.debugIndicatorPhase = UpdateIndicatorPhase(debugParams: call.params)
                return .value(.object(["phase": .string(String(describing: updater.indicatorPhase))]))
            },
        ])
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The web views under `view` (an open popover's page is in its own window).
    private static func webViewCount(in view: NSView) -> Int {
        view.subviews.reduce(view is WKWebView ? 1 : 0) { $0 + webViewCount(in: $1) }
    }
    #endif

    static func json(_ status: UpdaterStatus, log: [String]) -> JSONValue {
        .object([
            "track": .string(status.track.rawValue),
            "bundle_id": status.bundleIdentifier.map(JSONValue.string) ?? .null,
            "version": .string(status.version),
            "build": .string(status.build),
            "minimum_system_version": status.minimumSystemVersion.map { .string($0.description) } ?? .null,
            "system_version": .string(status.system.description),
            "feed_url": .string(status.feedURL),
            "sparkle_enabled": .bool(status.sparkleDisabledReason == nil),
            "sparkle_disabled_reason": status.sparkleDisabledReason.map { .string($0.rawValue) } ?? .null,
            "automatic_checks": .bool(status.automaticChecks),
            "automatic_downloads": .bool(status.automaticDownloads),
            "phase": .string(status.phase.rawValue),
            "detected_version": status.detectedVersion.map(JSONValue.string) ?? .null,
            "probing": .bool(status.probing),
            "last_probe": status.lastProbe.map(json) ?? .null,
            "last_probe_error": status.lastProbeError.map(JSONValue.string) ?? .null,
            "channel_switch_target": status.channelSwitchTarget.map { .string($0.rawValue) } ?? .null,
            "test_feed": status.testFeedURL.map(JSONValue.string) ?? .null, "ring": .string(status.ring.rawValue),
            "card": status.card.map { card in
                let shown = status.cardPresentation ?? card.presentation(version: status.version, build: status.build)
                return .object(["kind": .string(card.kind), "title": .string(shown.title),
                                "detail": shown.detail.map(JSONValue.string) ?? .null,
                                "lines": .array(shown.lines.map(JSONValue.string)),
                                "actions": .array(shown.actions.map { .string($0.rawValue) })])
            } ?? .null,
            "badge": status.badge.map(JSONValue.string) ?? .null,
            "log": .array(log.suffix(20).map(JSONValue.string)),
        ])
    }

    private static func json(_ probe: UpdateProbeResult) -> JSONValue {
        var fields: [String: JSONValue] = [
            "result": .string(probe.outcome.kind),
            "track": .string(probe.track.rawValue),
            "feed_url": .string(probe.feedURL),
            "current_version": .string(probe.currentVersion),
            "current_build": .string(probe.currentBuild),
            "system_version": .string(probe.system.description),
            "item_count": JSONValue(probe.itemCount),
            "checked_at": .string(ISO8601DateFormatter().string(from: probe.checkedAt)),
        ]
        switch probe.outcome {
        case .updateAvailable(let item):
            fields["offered"] = json(item)
        case .upToDate(let latest):
            fields["latest"] = latest.map(json) ?? .null
        case .requiresNewerSystem(let item, let required):
            fields["newer"] = json(item)
            fields["required_system_version"] = .string(required.description)
        }
        return .object(fields)
    }

    private static func json(_ item: AppcastItem) -> JSONValue {
        .object([
            "version": .string(item.version),
            "display_version": .string(item.displayVersion),
            "minimum_system_version": item.minimumSystemVersion.map { .string($0.description) } ?? .null,
            "release_notes": item.releaseNotesURL.map { .string($0.absoluteString) } ?? .null,
        ])
    }
}
