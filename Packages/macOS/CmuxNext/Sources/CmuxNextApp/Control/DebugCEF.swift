import AppKit
import CmuxNextBrowser
import CmuxNextChromiumRuntime
import CmuxNextDesign
import CmuxNextInputDiagnostics
import CmuxNextSettings
import Darwin

/// `debug.cef`: how Chromium started in this process (lazy tab, or a warm
/// start and why), its timings, the app's memory footprint, the default
/// engine, why Chromium is unavailable (`unavailable`: `notBundled`,
/// `downloading`, `downloadFailed`, `startFailed`, `shutDown`), where the
/// runtime came from (`runtime`: Chromium on demand) and the WebKit
/// fallbacks so far, where Chromium's browser process runs (`backend`:
/// `inProcess` or `host`; `host_supervisor`: host mode's one host), what the fork's page tracker read from host views
/// (`tracker`; in host mode only `tracker.hosted_pages`) and, in process only,
/// the external pump's counters (`pump`), the page windows over each
/// DevTools tab (`devtools[].child_windows`) and what swipe gestures asked
/// of their pages (`swipe`: page probes, wheel acks).
/// Helper processes are separate; measure them with `ps`.
@MainActor
enum DebugCEF {
    static func report(_ services: AppServices) -> JSONValue {
        let report = services.cache.cef.startReport
        var object: [String: JSONValue] = [
            "state": .string(report.state),
            "preloaded": .bool(report.preloaded),
            "likely": services.chromiumWarmup.reason.map { .string($0.rawValue) } ?? .null,
            "trigger": report.trigger.map { .string($0) } ?? .null,
            "footprint_mb": .number(footprintMegabytes()),
            "spare_window": .string(services.cache.cef.spareWindowState),
            "pages_spare_window": .string(services.cache.cef.pagesSpareWindowState),
            // Whether the warm-up keeps spare windows (null before it starts); the bench's host arms check it.
            "warmup_spare_windows": services.chromiumWarmup.startedPlacement.map { .bool($0.keepsSpareWindows) } ?? .null,
            // A window a spare would have served, built because none was ready.
            "window_built_on_key_turn": .number(Double(services.cache.cef.windowsBuiltOnKeyTurn)),
            "engine_start_main_ms": .number(milliseconds(services.cache.cef.engineStartMainThreadTime)),
            "start_steps": .array(services.cache.cef.startMarks.map {
                .object(["name": .string($0.name), "start_uptime_ns": .number(Double($0.startUptimeNanos)), "ms": .number($0.milliseconds)])
            }),
            "prefetch": services.cache.cef.frameworkPrefetchFields.map { .object($0.mapValues { .number($0) }) } ?? .null,
        ]
        if case let browserTabs = services.cache.browserTabs {
            object["default_engine"] = .string(browserTabs.preference.defaultEngine.rawValue)
            // The engine's reason, not `browserTabs.cefUnavailable()`: that read asks for the download.
            object["unavailable"] = unavailable(services.cache.cef.unavailableReason)
            let fallbacks = browserTabs.fallbacks
            object["fallback"] = fallbacks.count == 0 ? .null : .object([
                "count": .number(Double(fallbacks.count)),
                "reason": unavailable(fallbacks.lastReason),
                "source": fallbacks.lastSource.map { .string($0.rawValue) } ?? .null,
                "notified": .bool(fallbacks.notified),
            ])
        }
        let backend = services.chromiumRuntime.backend
        object["backend"] = .string(backend.rawValue)
        object["runtime"] = runtime(services.chromiumRuntime)
        object["host_supervisor"] = hostSupervisor(services.chromiumRuntime.source.hostSupervisor)
        object["devtools"] = .array(devTools(services, pageWindows: ChildPageGeometry.hasPageWindows(backend)))
        object.merge(engineCounters(backend: backend, pump: services.cache.cef.pumpStats,
                                    tracker: services.cache.cef.trackerStats)) { $1 }
        object["windows"] = windows(services.cache.cef.windowReport)
        // Host mode with feature chromiumHostWidgets: null without a widget host.
        object["host_widgets"] = services.cache.cef.hostWidgets.map { .array($0.map(hostWidget)) } ?? .null
        object["host_popup_menus"] = .bool(services.cache.cef.drawsHostPopupMenus)
        // Host mode with feature chromiumHostSuggestions: null while the host draws none in cmux.
        object["host_suggestions"] = services.cache.cef.hostSuggestions.map { .array($0.map(hostSuggestion)) } ?? .null
        // Host mode with feature chromiumHostFileDialogs: the page file choosers cmux answered.
        object["host_file_dialogs"] = services.cache.cef.hostFileDialogs.map { report in
            .object(["asked": .number(Double(report.asked)), "answered": .number(Double(report.answered)),
                     "waiting": .number(Double(report.waiting))])
        } ?? .null
        // Feature chromiumHangFollowsVisibility: each tab's renderer hang; null with the feature off.
        object["renderer_hangs"] = services.cache.cef.rendererHangs.map { hangs in
            .array(hangs.map { hang in
                .object(["browser": .number(Double(hang.browser)), "title": hang.title.map(JSONValue.string) ?? .null,
                         "prompting": .bool(hang.prompting), "held": .bool(hang.held), "shown": .bool(hang.shown)])
            })
        } ?? .null
        // Host mode with feature chromiumHostLocks: the key window's page view's locks.
        let lockPage = (NSApp.keyWindow?.firstResponder as? ChromiumHostPageView)
        object["host_locks"] = services.cache.cef.hostLocks(page: lockPage).map(hostLocks) ?? .null
        // Host mode with feature chromiumHostChoosers: null while cmux shows none of the host's choosers.
        object["host_choosers"] = services.cache.cef.hostChoosers.map { report in
            .object(["color_open": .bool(report.colorOpen), "device_choosers": .number(Double(report.deviceChoosers)),
                     "screen_shares": .number(Double(report.screenShares)), "answers": .number(Double(report.answers))])
        } ?? .null
        object["host_resize"] = services.cache.cef.hostResizeCounters.map { counters in .object(counters.mapValues { value in .number(value) }) } ?? .null
        // Host mode with feature chromiumHostHangBanner: the busy banner's deadline and the host's hangs.
        object["host_hang"] = services.cache.cef.hostHangCounters.map { counters in .object(counters.mapValues { value in .number(value) }) } ?? .null
        // Swipes over Chromium pages: a hosted page on a host that acks wheels probes nothing.
        let swipe = services.cache.cef.swipeStats
        object["swipe"] = .object([
            "gestures": .number(Double(swipe.gestures)), "probes": .number(Double(swipe.probes)),
            "acks": .number(Double(swipe.acks)), "swipes": .number(Double(swipe.swipes)),
            "host_acks_wheels": .bool(swipe.hostAcksWheels),
        ])
        if let duration = report.loadDuration { object["load_ms"] = .number(milliseconds(duration)) }
        if let duration = report.initializeDuration { object["initialize_ms"] = .number(milliseconds(duration)) }
        if let seconds = report.readyAfterLaunch { object["ready_after_launch_s"] = .number(seconds) }
        return .object(object)
    }

    private static func hostLocks(_ report: CEFHostLocksReport) -> JSONValue {
        let browser: (Int32?) -> JSONValue = { $0.map { .number(Double($0)) } ?? .null }
        return .object(["installed": .bool(report.installed), "asked": .number(Double(report.asked)),
                        "granted": .number(Double(report.granted)), "pointer": browser(report.pointer),
                        "unadjusted_movement": .bool(report.unadjustedMovement), "cursor_held": .bool(report.cursorHeld),
                        "keyboard": browser(report.keyboard),
                        "holds_keys": .bool(report.holdsKeys), "fullscreen": browser(report.fullscreen)])
    }

    /// Per shown Chromium tab: its DevTools state, the page and docked
    /// DevTools areas and, when Chromium's pages are child windows
    /// (`pageWindows`, in process), the Chromium child windows over the tab
    /// (screen coordinates, AppKit origin), so a check can see that the
    /// DevTools window sits exactly over its area.
    private static func devTools(_ services: AppServices, pageWindows: Bool) -> [JSONValue] {
        var out: [JSONValue] = []
        for controller in services.windows.controllers {
            guard let window = controller.window else { continue }
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard case .browser(let entry)? = pane.currentContent, let tab = entry.tab as? CEFTab else { continue }
                let state = tab.devTools
                var object: [String: JSONValue] = [
                    "tab": .string(tab.id.rawValue), "pane": .string(pane.paneKey),
                    "url": tab.state.url.map { .string($0.absoluteString) } ?? .null,
                    "title": tab.state.title.map { .string($0) } ?? .null,
                    "open": .bool(state.isOpen), "dock": .string(state.dock.rawValue),
                    // Host mode: the page's cursor (CSS name), tooltip text and accessibility element (idle, asking,
                    // refused, connected) in its page view; null in process. `tooltip_shown`: the app's tooltip on
                    // screen now, whoever's (chromium-host-bench.py's tooltip row: the page's shows while the
                    // pointer stays over the page).
                    "page_cursor": ChromiumHostPageView.first(in: tab.contentView)?.pageCursorName.map(JSONValue.string) ?? .null,
                    "page_tooltip": ChromiumHostPageView.first(in: tab.contentView)?.pageTooltipText.map(JSONValue.string) ?? .null,
                    "tooltip_shown": TooltipPresenter.shared.shown.map { JSONValue.string($0.text) } ?? .null,
                    "page_accessibility": ChromiumHostPageView.first(in: tab.contentView)?.remoteAccessibilityPhaseName.map(JSONValue.string) ?? .null,
                    // Host mode: drags the page view sent as DragTarget calls (null in process).
                    "page_drag": ChromiumHostPageView.first(in: tab.contentView).map { pageDrag($0.dragCounts) } ?? .null,
                ]
                if let panel = tab.sidePanelDiagnostic {
                    object["side_panel"] = .object(["title": .string(panel.title), "pinned": .bool(panel.pinned),
                                                    "controls": .array(panel.controls.map { .string($0) }), "frame": rect(panel.frame),
                                                    "chromium_focusable": panel.chromiumFocusable.map { .number(Double($0)) } ?? .null])
                }
                if let frames = tab.devToolsDiagnosticFrames {
                    object["page_frame"] = rect(frames.page)
                    object["devtools_frame"] = frames.devTools.map(rect) ?? .null
                    if pageWindows {
                        let content = frames.devTools.map { frames.page.union($0) } ?? frames.page
                        let children = WindowOverlayLayer.contentChildWindows(of: window).filter { $0.frame.intersects(content) }
                        object["child_windows"] = .array(children.map { child in
                            .object(["frame": rect(child.frame), "devtools": .bool(tab.devToolsContains(window: child)),
                                     "key": .bool(child.isKeyWindow), "visible": .bool(child.isVisible)])
                        })
                    }
                }
                out.append(.object(object))
            }
        }
        return out
    }

    private static func pageDrag(_ counts: ChromiumHostDragCounts) -> JSONValue {
        .object(["takes_drags": .bool(counts.takesDrags), "enters": .number(Double(counts.enters)),
                 "drops": .number(Double(counts.drops)), "answers": .number(Double(counts.answers))])
    }

    /// Runs `control` on the first shown Chromium tab with a side panel.
    static func pressSidePanel(_ control: String, services: AppServices) {
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard case .browser(let entry)? = pane.currentContent, let tab = entry.tab as? CEFTab else { continue }
                if tab.pressSidePanelForDebug(control) { return }
            }
        }
    }

    /// Chromium never opens a window of its own: `chromium_windows` must be
    /// empty; `guard_blocked` counts windows the app hid after they showed.
    private static func windows(_ report: CEFWindowReport) -> JSONValue {
        .object([
            "chromium_windows": .array(report.chromiumWindows.map { .string($0) }),
            "requests": .number(Double(report.requests)),
            "refused": .number(Double(report.refused)),
            "recent": .array(report.recent.map { .string($0) }),
            "blocked_commands": .array(report.blockedCommands.map { .number(Double($0)) }),
            "fork_foreign_browsers": .number(Double(report.foreignBrowsers)),
            "guard_blocked": .number(Double(report.guardBlocked)),
            "guard_recent": .array(report.guardRecent.map { .string($0) }),
            "unplaced_tabs": .number(Double(report.unplacedTabs)),
            "fork_api": .number(Double(report.forkAPIVersion)),
            "process_reuse_per_renderer_devtools": .bool(report.processReusePerRendererDevTools),
            "popup_windows": .array(report.popupWindows.map { .string($0) }),
        ])
    }

    /// One widget the Chromium host shows in cmux: its kind, ids and where it is on screen.
    private static func hostWidget(_ widget: CEFHostWidgetReport) -> JSONValue {
        .object(["kind": .string(widget.kind), "widget": .number(Double(widget.widget)), "owner": .number(Double(widget.owner)),
                 "context_id": .number(Double(widget.contextID)), "shown": .bool(widget.shown), "frame": rect(widget.screenFrame)])
    }

    private static func hostSuggestion(_ list: CEFHostSuggestionReport) -> JSONValue {
        .object(["browser": .number(Double(list.browser)), "token": .number(Double(list.token)), "kinds": .array(list.kinds.map { .string($0) }),
                 "types": .array(list.types.map { .number(Double($0)) }), "highlighted": list.highlighted.map { .number(Double($0)) } ?? .null,
                 "frame": list.screenFrame.map(rect) ?? .null, "field": list.field.map(rect) ?? .null])
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
    }

    /// The engine's counters, by backend. In process: the external pump's (`pump`) and the fork's
    /// page tracker's (`tracker`). In host mode the pump and the fork's tracker run in the Chromium
    /// Host; this process still counts its hosted page views (`ChromiumHostPageView`), so `tracker`
    /// has `hosted_pages` alone.
    static func engineCounters(backend: BrowserBackend, pump: CEFPumpStats?, tracker: CEFTrackerStats) -> [String: JSONValue] {
        guard backend == .inProcess else {
            return ["tracker": .object(["hosted_pages": .number(Double(tracker.hostedPages))])]
        }
        var counters: [String: JSONValue] = ["tracker": trackerReport(tracker)]
        if let pump { counters["pump"] = pumpReport(pump) }
        return counters
    }

    /// Pump wakeups per second = the change of `work_runs` over an interval.
    static func pumpReport(_ stats: CEFPumpStats) -> JSONValue {
        .object([
            "work_runs": .number(Double(stats.workRuns)),
            "immediate_requests": .number(Double(stats.immediateRequests)),
            "delayed_requests": .number(Double(stats.delayedRequests)),
            "reentrant_fires": .number(Double(stats.reentrantFires)),
            "long_work_runs": .number(Double(stats.longWorkRuns)),
            "kept_cross_thread_requests": .number(Double(stats.keptCrossThreadRequests)),
            "work_ms": .number(stats.workSeconds * 1_000),
            "passes_while_input_pending": .object(stats.passesWhileInputPending.byName.mapValues { .number(Double($0)) }),
            "deferred_for_input": .number(Double(stats.deferredForInput)),
            "pass_ms_p99": .number(stats.passMillisecondsP99),
            "early_passes": .number(Double(stats.earlyPasses)),
            "frame_deadline_waits": .number(Double(stats.frameDeadlineWaits)),
            "frame_input_holds": .number(Double(stats.frameInputHolds)),
        ])
    }

    /// `debug.input` section `pump`: the in-process pump's input policy counters; none, and no
    /// engine built, before a Chromium need built the engine.
    static func pumpInputSource(_ chromium: ChromiumEngineSlot) -> DebugInputPumpSource {
        DebugInputPumpSource(read: { [weak chromium] in
            chromium?.built?.pumpStats.map {
                DebugInputPump(passesWhileInputPending: $0.passesWhileInputPending.byName,
                               deferredForInput: UInt64(clamping: $0.deferredForInput), passMillisecondsP99: $0.passMillisecondsP99)
            }
        }, reset: { [weak chromium] in chromium?.built?.resetPumpInputCounters() })
    }

    /// `debug.input` section `chromium`: Chromium's own EventLatency and ScrollJank histograms,
    /// read through `Browser.getHistograms` on each read only. Builds no engine: before one exists the section
    /// says `unavailable: not_started`.
    static func histogramSource(_ chromium: ChromiumEngineSlot) -> DebugInputSectionSource<ChromiumInputHistograms> {
        let reader = CEFHistogramReader(engine: chromium)
        return DebugInputSectionSource(section: .chromium, read: { await reader.read() }, reset: { await reader.reset() })
    }

    /// Per action = the change of each counter over it (scripts/cmux-next/pane-perf-terminal.py --browser).
    private static func trackerReport(_ stats: CEFTrackerStats) -> JSONValue {
        .object([
            "clip_reads": .number(Double(stats.clipReads)),
            "occlusion_reads": .number(Double(stats.occlusionReads)),
            "clip_builds": .number(Double(stats.clipBuilds)),
            "clip_hits": .number(Double(stats.clipHits)),
            "clip_ms": .number(stats.clipSeconds * 1_000),
            "geometry_posts": .number(Double(stats.geometryPosts)),
            "hosted_pages": .number(Double(stats.hostedPages)),
            // Keyed by the page window's kind: "page", "devtools", "popup", "popup_window".
            "hosted_pages_by_widget": .object(stats.hostedPagesByWidget.mapValues { JSONValue.number(Double($0)) }),
            "hosting_refused": .number(Double(stats.hostingRefused)),
            "hosting_widget_fallbacks": .number(Double(stats.hostingWidgetFallbacks)),
            "hosting_without_track_a": .number(Double(stats.hostingWithoutTrackA)),
            "pages_attached": .number(Double(stats.pagesAttached)),
            "attach_refused": .number(Double(stats.attachRefused)),
            "geometry_skips": .number(Double(stats.geometrySkips)),
            "page_window_widget_shows": .number(Double(stats.pageWindowWidgetShows)),
            // Keyed by the fork's widget kind (CEFNativeWidget raw value): "2" autofill, "5" print preview.
            "page_window_widget_shows_by_kind": .object(Dictionary(stats.pageWindowWidgetShowsByKind.map {
                (String($0.key), JSONValue.number(Double($0.value)))
            }, uniquingKeysWith: { first, _ in first })),
        ])
    }

    /// Where the runtime came from and the download state (Chromium on demand).
    private static func runtime(_ service: ChromiumRuntimeService) -> JSONValue {
        var object: [String: JSONValue] = [
            "origin": .string(service.origin.rawValue),
            "pinned_key": service.pinnedKey.map { .string($0) } ?? .null,
            "install": .string(service.state.name),
            "fraction": service.state.fraction.map { .number($0) } ?? .null,
            "frameworks": service.source.layout.map { .string($0.frameworksDirectory.path) } ?? .null,
            // `host` when Chromium tabs run in the Chromium Host (chromium-popups-live.py --window-requests).
            "backend": .string(service.source.backend.rawValue),
        ]
        if case .failed(let error, let attempt) = service.state {
            object["error"] = .object(["code": .string(error.code), "detail": .string(error.detail), "attempt": .number(Double(attempt))])
        }
        return .object(object)
    }

    /// Host mode's one supervisor: its running host's pid, the hosts it started, how they ended
    /// and why none can start. Null in process. chromium-host-bench.py's profiles row tells its host from others.
    private static func hostSupervisor(_ supervising: (any ChromiumHostSupervising)?) -> JSONValue {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let supervisor = supervising as? ChromiumHostSupervisor else { return .null }
        return .object([
            "pid": supervisor.hostPID.map { .number(Double($0)) } ?? .null,
            "hosts_started": .number(Double(supervisor.hostsStarted)),
            "exits": .array(supervisor.exits.map(JSONValue.string)),
            "start_failure": supervisor.startFailure.map(JSONValue.string) ?? .null,
        ])
        #else
        .null
        #endif
    }

    private static func unavailable(_ reason: CEFUnavailableReason?) -> JSONValue {
        guard let reason else { return .null }
        return .object(["code": .string(reason.code), "detail": reason.detail.map { .string($0) } ?? .null])
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// `phys_footprint` (Activity Monitor's "Memory"), in MiB.
    static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        // SAFETY: `count` is task_vm_info_data_t's size in integer_t words, the capacity the rebound view
        // covers; task_info writes at most `count` words into `info`, a local live for the call, and
        // lowers `count` to what it wrote.
        let result = unsafe withUnsafeMutablePointer(to: &info) { pointer in
            unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
