import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowserImport
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextErrorJournal
import CmuxNextInput
import CmuxNextInputDiagnostics
import CmuxNextPages
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextWakeups

#if DEBUG || CMUX_BENCH_HOOKS
/// The debug drivers (tagged DEV and bench builds): synthetic keys and bursts, fixtures, recordings,
/// showcase scenes and deliberate stalls. One control launch group (`AppControl.launchGroups`).
enum DebugDriverControl {
    static func register(on router: ControlRouter, services: AppServices, keys keySequencePlayer: DebugKeySequencePlayer) {
        // Deliberately blocks the main thread (watchdog and bench self-test).
        router.register([
            .mainActor("debug.home.drive") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugHomeNativeFixture.drive(call.params, services: services))
            },
            .mainActor("debug.window_record") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugWindowRecord.start(call.params, services: services))
            },
            .async("debug.shortcut_hints") { [weak services] call in
                await DebugShortcutHintControl().handle(call.params, services: services)
            }.withDeadline(.fixed(.seconds(4))),
            .mainActor("debug.showcase.seed") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugShowcase.seed(call.params, services: services))
            },
            .mainActor("debug.scene.list") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(CaptureSceneRegistry(services: services).list())
            },
            .async("debug.scene.render") { [weak services] call in
                guard let services else { return .null }
                return await CaptureSceneRegistry(services: services).render(call.params)
            }.withDeadline(.fixed(.seconds(30))),
            .mainActor("debug.webkit_inspector") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugWebInspector.handle(call.params, services: services))
            },
            // Open popup panels (sized window.open popups).
            .async("debug.popups") { [weak services] call in
                guard let services else { return .null }
                return await DebugPopups.report(call.params, services: services)
            },
            // Scripted input into the real agent cursor stacks (visual checks).
            .mainActor("debug.agent_cursor.demo") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAgentCursorDemo.handle(call.params, services: services))
            },
            // A click on an agent cursor's name tag, as the person's (the tag is a link).
            .mainActor("debug.agent_cursor.click_tag") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAgentCursor.clickTag(call.params, services: services))
            },
            // An injected key is input: it runs ahead of queued requests and batches yield to it (MainWorkClass.input).
            .mainActor("debug.key") { [weak services, player = keySequencePlayer] call in
                guard let services else { return .value(.null) }
                if call.params["sequence"] != nil { return .value(DebugKey.sendSequence(call.params, services: services, player: player)) }
                return .value(DebugKey.send(call.params, services: services))
            }.injectingInput(),
            // The app's resign and become-active path without activating it (DebugAppActivation).
            .mainActor("debug.app_activation") { call in
                .value(DebugAppActivation.send(call.params))
            },
            // What this launch runs of the shipping configuration idle-budget measures.
            ShippingModeReport { @MainActor [weak services] in
                guard let services else { return nil }
                let hangReports = await AppProcessRoot.shared.hangReports?.shippingModeState(setting: services.settings?.snapshot.hangReports)
                return ShippingModeReport.State(drawsWhenOccluded: WindowDrawPolicy.drawsWhenOccluded,
                                                pagesRenderWhenCovered: PageWebView.rendersWhenCovered(ProcessInfo.processInfo.environment),
                                                sentryShouldStart: services.crashReporting.reporter.policy.shouldStart,
                                                hangReports: hangReports ?? .init(available: false, setting: nil, decision: nil, enabled: false))
            }.method,
            .async("debug.palette.capture") { [weak services] call in
                guard let services else { return .null }
                return await DebugPaletteCapture.capture(call.params, services: services)
            },
            // `debug.palette.entries {scope?, path}`: writes the scope's ranker input (the
            // palette-ranking eval fixture, plans/cmux-next/palette-ranking.md) to `path`.
            .async("debug.palette.entries") { [weak services] call in
                try await DebugPaletteEntries.write(call.params, services: services)
            },
            .mainActor("debug.omnibar_mouse") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.mouse(call.params, services: services))
            },
            // One omnibar click from rest to the frame that shows focus and select-all (omnibar-mousedown-latency).
            .async("debug.omnibar_bench") { [weak services] call in
                await DebugOmnibarClickBench.run(call.params, services)
            }.withDeadline(.fixed(.seconds(15))),
            // One file-picker open, click to the frame that shows it (DebugOpenPanelBench).
            .async("debug.open_panel_bench") { [weak services] call in
                await DebugOpenPanelBench.run(call.params, services)
            }.withDeadline(.fixed(.seconds(30))),
            .mainActor("debug.omnibar_type") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.type(call.params, services: services))
            },
            .async("debug.window.ax_set_frame") { [weak services] call in
                guard let services else { return .null }
                return await DebugAXFrame.run(call.params, services: services)
            },
            .mainActor("debug.home_native_fixture.open") { [weak services] call in
                guard let services else { return .value(.null) }
                let attachments = call.params["attachments"]?.boolValue ?? false
                // `new`: one more fixture tab, also when the window lists one already.
                let fresh = call.params["new"]?.boolValue ?? false
                return .value(DebugHomeNativeFixture.open(services: services, attachments: attachments, fresh: fresh))
            },
            // `debug.home.attach` {paths: [..] | path, via: drop|paste|pick}:
            // files enter the shown Home composer through the same intake as
            // a real drop, paste or pick (HomeNativeTranscriptView.attachFiles).
            .mainActor("debug.home.attach") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugHomeNativeFixture.attach(call.params, services: services))
            },
            .mainActor("debug.window_list") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugWindowList.list(services: services))
            },
            .mainActor("debug.page_popup") { _ in .value(DebugPagePopup.list()) },
            .async("debug.window_snapshot") { [weak services] call in
                guard let services else { return .null }
                return await DebugWindowSnapshot.captureAsync(call.params, services: services)
            },
            .mainActor("debug.window.focus") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.focusWindow(call.params, services: services))
            },
            .mainActor("debug.window_frame") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.setWindowFrame(call.params, services: services))
            },
            .mainActor("debug.drop_highlight") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.dropHighlight(call.params, services: services))
            },
            .mainActor("debug.sidebar_filter") { [weak services] call in .value(services.map { DebugSidebarFilter.run(call.params, $0) } ?? .null) },
            .mainActor("debug.sidebar_rows") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarRows.report(call.params, services: services))
            },
            .mainActor("debug.sidebar_wheel") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarWheel.post(call.params, services: services))
            },
            .mainActor("debug.sidebar_rename") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.beginSidebarRename(call.params, services: services))
            },
            // CEF's own DevTools wait is 5 s (CEFRuntime.devToolsTimeout); the 2 s
            // control-plane deadline cut off replies that arrive between 2 and 5 s.
            .async("debug.cef.devtools") { [weak services] call in
                await DebugExtensions.devTools(call.params, services)
            }.withDeadline(.fixed(.seconds(6))),
            // React agent pane: synthetic transcript, fling and frame/typing
            // timing through the page's cmuxAcpmuxDebug, WebContent pid.
            .async("debug.agent_pane") { [weak services] call in
                await DebugAgentPane.handle(call.params, services)
            }.withDeadline(.fixed(DebugAgentPane.deadline)),
            // A list's composited frames read off main, around a stall (ScrollFrameProbe).
            .async("debug.scroll_frames") { [weak services] call in
                guard let services else { return .null }
                return await scrollFrames(call.params, services)
            }.withDeadline(.fixed(.seconds(15))),
            // Instant new tab: spares, opening times, the field (new-tab.md 2.3); new terminal stages (cx-6so.58).
            .async("debug.new_tab") { [weak services] call in
                await DebugNewTab.handle(call.params, services)
            }.withDeadline(.fixed(.seconds(15))), DebugNewTerminalTrace.method(services),
            // Agent chat open: stages and the pane's surface per frame (Leo 2026-10-22, the black gap).
            DebugChatOpenTrace.method(services),
            // R131: hover card retarget timing across the focused strip's tabs.
            .async("debug.hover_sweep") { [weak services] call in
                guard let services else { return .null }
                return await DebugHoverSweep.run(call.params, services: services)
            }.withDeadline(.fixed(.seconds(15))),
            // `debug.pointer_hover {point: [x, y] | null, window?}`: real tracking-area
            // enter/move/exit at a window point (cx-tupd; a headless host cannot hover).
            .mainActor("debug.pointer_hover") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugPointerHover.run(call.params, services: services))
            },
            .mainActor("debug.menu") { [weak services] call in
                .value(DebugExtensions.menu(call.params, presenter: services?.contextMenus, popupMenu: services?.cache.chromium.built?.hostPopupMenu))
            },
            // The browser-data import offer on the first browser tab.
            .mainActor("debug.browser_import_offer") { [weak services] call in
                .value(services.map { DebugBrowserImportOffer.run(call.params, services: $0) } ?? .null)
            },
            .mainActor("debug.onboarding") { [weak services] call in
                .value(services.map { DebugOnboarding.run(call.params, services: $0) } ?? .null)
            },
            .mainActor("debug.extensions.toolbar") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.toolbar(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.click") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.click(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.menu") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.menu(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.drag") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.drag(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.popup") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.popup(call.params, $0) } ?? .null)
            },
            // The file pages: tabs, recovery drafts, toasts, and the notice's Open.
            .async("debug.filepages") { [weak services] call in
                guard let services else { return .null }
                return await DebugFilePages.run(call.params, services)
            },
            // The quit sheet (Quit and the local terminals).
            .mainActor("debug.quit") { [weak services] call in
                .value(services.map { DebugQuit.run(call.params, $0) } ?? .null)
            },
            // A quit as a logout does (REOPEN VIDEO): {reason: "logout"}.
            .mainActor("debug.app.terminate") { [weak services] call in
                .value(services.map { $0.quit.origins.debugTerminate(reason: call.params["reason"]?.stringValue, center: NSWorkspace.shared.notificationCenter) { NSApplication.terminateFromRunLoop() } }
                    .map { refusal in refusal.map { .object(["error": .string($0)]) } ?? .object(["terminating": .bool(true)]) } ?? .null)
            },
            // The burst bench's record: each press's outcome, refusals, terminal grids, echoes and redraws.
            // `status`: whether the burst is done (its keys posted, no create still asking the daemon, no
            // grid waiting to go or for its echo), the signal the bench waits for before it reads the counts.
            .mainActor("debug.burst") { [weak services, player = keySequencePlayer] call in
                .value(services.map { services in
                    services.burstTrace.control(call.params, facts: [
                        "key_repeat_delay_s": .number(NSEvent.keyRepeatDelay), "key_repeat_interval_s": .number(NSEvent.keyRepeatInterval),
                        "sequence_playing": .bool(player.isPlaying),
                        "pending_intents": JSONValue(services.daemon.store.pendingIntents.count),
                        "resize_idle": .bool(services.resizes.isIdle),
                        // The attach machines' own due echoes: a closed view is gone from the cache, so it never waits.
                        "terminals_awaiting_echo": JSONValue(services.cache.terminals.values.filter { $0.io.awaitsEcho }.count),
                    ])
                } ?? .null)
            },
            // Every window's toasts (R96): list, a person's action run, the undo key.
            .mainActor("debug.toast") { [weak services] call in
                .value(services.map { DebugToast.run(call.params, $0) } ?? .null)
            },
            // Every open cmux dialog (R96): list, fixtures, keys, presses.
            .mainActor("debug.dialog") { [weak services] call in
                .value(services.map { DebugDialog.run(call.params, $0) } ?? .null)
            },
            // The Passwords reveal sheet with a fixture secret (no store, no device owner prompt), so a
            // live check proves the sheet stays out of screen capture (cx-bkyn9).
            .mainActor("debug.passwords_reveal") { [weak services] call in
                guard let services else { return .value(.null) }
                let secret = SecretBytes(copying: Array((call.params["secret"]?.stringValue ?? "fixture").utf8))
                let surface = NativePasswordSecretSurface(pasteboard: ConcealedPasteboard(deadlines: services.mainDeadlines))
                let anchor = services.windows.active?.window?.contentView
                let site = call.params["site"]?.stringValue ?? "example.com"
                // task-owner: the reveal sheet's own lifetime; it ends when the sheet is answered or the app quits.
                // Off main until the sheet: the reveal itself is the surface's main-actor work.
                services.work.task(.userVisible) { await surface.reveal(secret, site: site, username: "proof", anchor: anchor) }
                return .value(["shown": .bool(true)])
            },
            .mainActor("debug.extensions.prompt") { [weak services] call in
                .value(services.map { DebugExtensionPrompts.run(call.params, $0) } ?? .null)
            },
            .mainActor("debug.crash.app") { [weak services] call in DebugCrashes.crashApp(call.params, services?.crashReporting) },
            .mainActor("debug.crash.exception") { [weak services] _ in .value(DebugCrashes.raiseException(services?.crashReporting)) },
            // Low Power Mode as WebKit tabs follow it: `enabled: bool` overrides
            // macOS (no sudo needed), `enabled: null` follows macOS again.
            .mainActor("debug.low_power_mode") { [weak services] call in
                guard let mode = services?.energyMonitor.lowPowerMode else { return .value(.null) }
                if let enabled = call.params["enabled"] { mode.override = enabled.boolValue }
                return .value(["enabled": .bool(mode.isEnabled), "override": mode.override.map { .bool($0) } ?? .null,
                               "system": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)])
            },
            // Reduce Transparency as overlays follow it (toasts, menus): `enabled: bool`
            // overrides macOS for this app only, `enabled: null` follows macOS again.
            .mainActor("debug.reduce_transparency") { call in
                let mode = ReduceTransparency.shared
                if let enabled = call.params["enabled"] { mode.override = enabled.boolValue }
                return .value(["enabled": .bool(mode.isEnabled), "override": mode.override.map { .bool($0) } ?? .null,
                               "system": .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)])
            },
            // `started_ns`, `ended_ns`: CLOCK_UPTIME_RAW around the stall, the clock `debug.scroll_frames` stamps frames with.
            .mainActor("debug.stall") { call in
                let milliseconds = min(max(call.params["ms"]?.intValue ?? 100, 1), 1_000)
                let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let end = ContinuousClock.now + .milliseconds(milliseconds)
                while ContinuousClock.now < end {}
                return .value(["stalled_ms": .number(Double(milliseconds)), "started_ns": .number(Double(started)),
                               "ended_ns": .number(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))])
            },
        ])
        // Sidebar fixtures and the sidebar focus ring live in CmuxNextSidebar behind DEBUG only, so a bench
        // build (CMUX_BENCH_HOOKS without DEBUG) registers these routes in DEBUG builds alone.
        #if DEBUG
        router.register([
            .mainActor("debug.sidebar_nested_fixture") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarNestedFixture.show(call.params, services: services))
            },
            .mainActor("debug.sidebar_group_drag") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarGroupDrag.run(call.params, services: services))
            },
            // `debug.view_key {view, key, modifiers?, window?}`: a real key-down/up into a
            // named view made first responder; `debug.focus_ring`: the sidebar's ring (cx-tupd).
            .mainActor("debug.view_key") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugViewKey.send(call.params, services: services))
            }.injectingInput(),
            .mainActor("debug.focus_ring") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugViewKey.focusRingReport(call.params, services: services))
            },
        ])
        #endif
    }

    /// `debug.scroll_frames {target: sidebar|palette, duration_ms, scale, scroll_to}`: ``ScrollFrameProbe`` on the
    /// active window's workspace list or the open palette's results.
    @MainActor private static func scrollFrames(
        _ params: [String: CmuxNextSettings.JSONValue], _ services: AppServices
    ) async -> CmuxNextSettings.JSONValue {
        let probe: ScrollFrameProbe?
        if params["target"]?.stringValue == "palette" {
            let palette = services.palette
            probe = palette.visiblePanel.flatMap { panel in palette.debugResultsScrollView.map { ScrollFrameProbe(window: panel, list: $0) } }
        } else {
            probe = services.windows.active.flatMap { c in c.window.map { ScrollFrameProbe(window: $0, list: c.sidebar.container.sidebarView.debugListScrollView) } }
        }
        let report = await probe?.run(scrollTo: params["scroll_to"]?.doubleValue, duration: params["duration_ms"]?.doubleValue ?? 1500,
                                      scale: params["scale"]?.doubleValue ?? 0.5, work: services.work)
        return report.flatMap { CmuxNextSettings.JSONValue(foundation: $0) } ?? .object(["error": .string("no such list on screen")])
    }
}
#endif
