import Testing
@testable import CmuxControlSocket

@Suite("ControlCommandExecutionPolicy")
struct ControlCommandExecutionPolicyTests {
    @Test func vmPrefixedMethodsRunOnTheSocketWorker() {
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.create") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.anything.else").runsOnSocketWorker)
    }

    @Test func remotesPrefixedMethodsRunOnTheSocketWorker() {
        // `cmux remotes` verbs make blocking authenticated web API calls, so
        // they must run on the worker; otherwise the dispatcher never reaches
        // their handler and returns method_not_found.
        #expect(ControlCommandExecutionPolicy(forMethod: "remotes.list") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "remotes.add") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "remotes.remove") == .socketWorker(mainThreadCallable: false))
    }

    @Test func aiAccountsPrefixedMethodsRunOnTheSocketWorker() {
        // `cmux ai-accounts` verbs make blocking authenticated web API calls, so
        // they must run on the worker; otherwise the dispatcher never reaches
        // their handler and returns method_not_found.
        #expect(ControlCommandExecutionPolicy(forMethod: "aiAccounts.list") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "aiAccounts.upload") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "aiAccounts.remove") == .socketWorker(mainThreadCallable: false))
    }

    @Test func fixedWorkerSetRunsOnTheSocketWorker() {
        for method in [
            "system.ping", "system.capabilities", "auth.status", "auth.sign_in_url",
            "feed.push", "browser.download.wait", "system.top", "system.memory",
            "workspace.remote.pty_bridge", "workspace.env", "sidebar.custom.reload",
            "sidebar.custom.open",
            "debug.sidebar.simulate_drag", "mobile.attach_ticket.create",
            "mobile.terminal.set_font",
            // JavaScript-evaluating browser methods block on page JS and must
            // not hold the main actor (see socketWorkerMethods rationale).
            "browser.eval", "browser.wait", "browser.snapshot", "browser.click",
            "browser.fill", "browser.navigate", "browser.get.text",
            "browser.find.text", "browser.highlight",
            // Adjacent WebKit/page-state methods wait on JS, cookie, or
            // capture callbacks and follow the same worker-lane contract.
            "browser.screenshot", "browser.frame.select", "browser.dialog.accept",
            "browser.dialog.dismiss", "browser.cookies.get", "browser.cookies.set",
            "browser.cookies.clear", "browser.storage.get", "browser.storage.set",
            "browser.storage.clear", "browser.console.list", "browser.console.clear",
            "browser.errors.list", "browser.state.save", "browser.state.load",
            "browser.addinitscript", "browser.addscript", "browser.addstyle",
        ] {
            #expect(ControlCommandExecutionPolicy(forMethod: method).runsOnSocketWorker, "\(method)")
        }
    }

    @Test func everythingElseRunsOnTheMainActor() {
        for method in [
            "workspace.create", "browser.url.get",
            "browser.open_split", "browser.get.title", "browser.frame.main",
            "mobile.terminal.create", "feed.jump", "vmx.create", "",
            // Focus-intent verbs stay on the main lane until the mutations
            // tranche decides them deliberately.
            "surface.focus", "workspace.select", "pane.focus", "window.focus",
        ] {
            let policy = ControlCommandExecutionPolicy(forMethod: method)
            #expect(policy == .mainActor, "\(method)")
            #expect(!policy.runsOnSocketWorker, "\(method)")
        }
    }

    @Test func v2ResolutionReadsRunOnTheWorkerAndAreMainThreadCallable() {
        // Tranche D (issue #5757): the implicit handle-normalization reads.
        // One controlResolveOnMain hop (refresh + witness + ref minting),
        // JSON build/encode on the worker; the hop collapses inline for the
        // main-thread in-process callers (cmuxTests drive these verbs via
        // handleSocketLine on the main actor).
        for method in [
            "surface.list", "surface.current",
            "workspace.list", "workspace.current",
            "window.list", "window.current", "window.displays",
            "pane.list", "pane.surfaces",
            "system.identify", "system.tree",
        ] {
            let policy = ControlCommandExecutionPolicy(forMethod: method)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(method)")
        }
    }

    @Test func v1ResolutionReadsRunOnTheWorkerAndAreMainThreadCallable() {
        for command in [
            "list_windows", "current_window", "list_workspaces",
            "list_surfaces", "current_workspace",
        ] {
            let policy = ControlCommandExecutionPolicy(forV1Command: command)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(command)")
        }
    }

    @Test func v2SendsRunOnTheWorkerAndAreMainThreadCallable() {
        // Tranche E (issue #5757): one narrow hop each (resolve target +
        // inject input + forceRefresh); parse and reply shaping on the
        // worker. surface.send_text MUST stay callable — the feed send-text
        // path (AppDelegate.handleFeedRequestSendText) drives it through
        // handleSocketLine on the main thread; surface.send_key shares the
        // identical non-blocking body shape.
        #expect(ControlCommandExecutionPolicy(forMethod: "surface.send_text") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "surface.send_key") == .socketWorker(mainThreadCallable: true))
    }

    @Test func v1SendsRunOnTheWorkerAndAreMainThreadCallable() {
        // send_workspace MUST stay callable (TerminalAndGhosttyTests drives
        // it through handleSocketLine on the main actor); the rest share the
        // identical single-hop non-blocking body shape.
        for command in [
            "send", "send_key", "send_surface", "send_key_surface",
            "send_workspace",
        ] {
            let policy = ControlCommandExecutionPolicy(forV1Command: command)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(command)")
        }
    }

    @Test func onlyPureProbesAreMainThreadCallable() {
        #expect(ControlCommandExecutionPolicy(forMethod: "system.ping") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "system.capabilities") == .socketWorker(mainThreadCallable: true))
        #expect(ControlCommandExecutionPolicy(forMethod: "system.top") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "vm.create") == .socketWorker(mainThreadCallable: false))
    }

    @Test func terminalReadsRunOnTheWorkerAndAreNotMainThreadCallable() {
        // Tranche C (issue #5757): the Ghostty capture is one v2MainSync hop,
        // the (possibly multi-MB) scrollback formatting runs on the worker.
        // NOT mainThreadCallable — a main-thread in-process caller would run
        // that formatting inline on the main thread, which is exactly the
        // stall the lane move removes, and no in-process caller needs it.
        #expect(ControlCommandExecutionPolicy(forMethod: "surface.read_text") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forMethod: "surface.read_selection") == .socketWorker(mainThreadCallable: false))
        #expect(ControlCommandExecutionPolicy(forV1Command: "read_screen") == .socketWorker(mainThreadCallable: false))
    }

    @Test func v1PingRunsOnTheWorkerAndIsMainThreadCallable() {
        // `ping` is the dispatcher's former hard-coded worker fast path; it is
        // a pure probe, so in-process main-thread callers may run it inline.
        let policy = ControlCommandExecutionPolicy(forV1Command: "ping")
        #expect(policy == .socketWorker(mainThreadCallable: true))
        #expect(policy.runsOnSocketWorker)
    }

    @Test func v1SidebarTelemetryFamilyRunsOnTheWorkerAndIsMainThreadCallable() {
        // The tranche-B telemetry family: parse/format on the worker, deferred
        // mutations on the ordered bus, at most one v2MainSync hop per
        // command. Every body is non-blocking end-to-end when run inline on
        // the main thread, so in-process main-thread callers (and cmuxTests
        // driving handleSocketLine on the main actor) stay callable.
        for command in [
            "set_status", "report_meta", "report_meta_block",
            "clear_status", "clear_meta", "clear_meta_block",
            "list_status", "list_meta", "list_meta_blocks",
            "set_agent_pid", "set_agent_lifecycle", "agent_hibernation",
            "clear_agent_pid",
            "log", "clear_log", "list_log", "set_progress", "clear_progress",
            "report_git_branch", "clear_git_branch",
            "report_pr", "report_review", "clear_pr", "report_pr_action",
            "report_ports", "clear_ports",
            "report_pwd", "report_shell_state", "report_tty", "ports_kick",
        ] {
            let policy = ControlCommandExecutionPolicy(forV1Command: command)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(command)")
        }
    }

    @Test func v2SurfaceTelemetryTwinsRunOnTheWorkerAndAreMainThreadCallable() {
        // The v2 twins of the report family share the same single-hop worker
        // bodies (encode off-main), so they carry the same policy.
        for method in [
            "surface.report_pwd", "surface.report_shell_state",
            "surface.report_tty", "surface.ports_kick",
        ] {
            let policy = ControlCommandExecutionPolicy(forMethod: method)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(method)")
        }
    }

    @Test func v1NotificationFamilyRunsOnTheWorkerAndIsMainThreadCallable() {
        // Tranche B2: parse on the worker; notify_target_async and
        // clear_notifications are pure bus enqueues, the synchronous verbs
        // carry one inline-collapsing v2MainSync hop, so main-thread
        // in-process callers stay safe.
        for command in [
            "notify", "notify_surface", "notify_target", "notify_target_async",
            "list_notifications", "clear_notifications",
        ] {
            let policy = ControlCommandExecutionPolicy(forV1Command: command)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(command)")
        }
    }

    @Test func v2NotificationCreateFamilyRunsOnTheWorkerAndIsMainThreadCallable() {
        // notification.reconcile is deliberately absent: it is a mobile-host
        // data-plane verb (v2MobileDispatch), not a control-socket method.
        for method in [
            "notification.create", "notification.create_for_surface",
            "notification.create_for_target", "notification.create_for_caller",
            "workspace.set_auto_title",
        ] {
            let policy = ControlCommandExecutionPolicy(forMethod: method)
            #expect(policy == .socketWorker(mainThreadCallable: true), "\(method)")
        }
        #expect(ControlCommandExecutionPolicy(forMethod: "notification.reconcile") == .mainActor)
        // The read-side notification verbs stay on the main lane.
        #expect(ControlCommandExecutionPolicy(forMethod: "notification.list") == .mainActor)
        #expect(ControlCommandExecutionPolicy(forMethod: "notification.clear") == .mainActor)
    }

    @Test func v1CommandsDefaultToTheMainActor() {
        for command in [
            "right_sidebar", "focus_surface",
            "sidebar_state", "reset_sidebar", "list_panes", "new_pane",
            "new_workspace", "select_workspace", "close_workspace",
            "help", "",
            // The v2 namespace prefix rules (vm./remotes.) and v2 worker
            // method names must not leak into v1 classification.
            "vm.create", "remotes.list", "system.ping",
            "surface.report_pwd", "notification.create",
        ] {
            let policy = ControlCommandExecutionPolicy(forV1Command: command)
            #expect(policy == .mainActor, "\(command)")
            #expect(!policy.runsOnSocketWorker, "\(command)")
        }
    }

    @Test func mainThreadCallableSetsAreSubsetsOfTheirWorkerLanes() {
        // The callable refinement only exists for worker-lane members; a
        // callable entry outside its lane would be dead policy.
        #expect(
            ControlCommandExecutionPolicy.mainThreadCallableSocketWorkerV1Commands
                .isSubset(of: ControlCommandExecutionPolicy.socketWorkerV1Commands)
        )
        #expect(
            ControlCommandExecutionPolicy.mainThreadCallableSocketWorkerMethods
                .isSubset(of: ControlCommandExecutionPolicy.socketWorkerMethods)
        )
    }

    @Test func v1WorkerLaneSetsArePinnedExactly() {
        // Exact-set pins so growing a lane is always a deliberate,
        // test-visible decision: adding a v1 worker verb fails here until the
        // author decides its mainThreadCallable flag (the callable set is an
        // explicit enumeration, NOT an alias of the worker set — that keeps
        // the v1 invalid_dispatch guard meaningful for future non-callable
        // verbs). The app-side backstop for a policy-listed verb with no
        // worker handler is the loud internal error in
        // socketWorkerV1ResponseIfHandled / socketWorkerV2Response (the
        // app-side hop set is not visible to this package, so lockstep with
        // it is enforced at runtime by that error, not here).
        let telemetry: Set<String> = [
            "set_status", "report_meta", "report_meta_block",
            "clear_status", "clear_meta", "clear_meta_block",
            "list_status", "list_meta", "list_meta_blocks",
            "set_agent_pid", "set_agent_lifecycle", "agent_hibernation",
            "clear_agent_pid",
            "log", "clear_log", "list_log", "set_progress", "clear_progress",
            "report_git_branch", "clear_git_branch",
            "report_pr", "report_review", "clear_pr", "report_pr_action",
            "report_ports", "clear_ports",
            "report_pwd", "report_shell_state", "report_tty", "ports_kick",
        ]
        #expect(ControlCommandExecutionPolicy.sidebarTelemetryV1Commands == telemetry)
        let notification: Set<String> = [
            "notify", "notify_surface", "notify_target", "notify_target_async",
            "list_notifications", "clear_notifications",
        ]
        #expect(ControlCommandExecutionPolicy.notificationV1Commands == notification)
        let terminalRead: Set<String> = ["read_screen"]
        #expect(ControlCommandExecutionPolicy.terminalReadV1Commands == terminalRead)
        let resolutionReads: Set<String> = [
            "list_windows", "current_window", "list_workspaces",
            "list_surfaces", "current_workspace",
        ]
        #expect(ControlCommandExecutionPolicy.resolutionReadV1Commands == resolutionReads)
        let sends: Set<String> = [
            "send", "send_key", "send_surface", "send_key_surface",
            "send_workspace",
        ]
        #expect(ControlCommandExecutionPolicy.terminalSendV1Commands == sends)
        let expectedWorker = telemetry.union(notification).union(terminalRead)
            .union(resolutionReads).union(sends).union(["ping"])
        #expect(ControlCommandExecutionPolicy.socketWorkerV1Commands == expectedWorker)
        // Every member except read_screen is deliberately main-thread
        // callable (deadlock-free inline: bus enqueues plus inline-collapsing
        // hops). read_screen opts out so its multi-MB formatting can never
        // run inline on the main thread.
        #expect(
            ControlCommandExecutionPolicy.mainThreadCallableSocketWorkerV1Commands
                == expectedWorker.subtracting(terminalRead)
        )
    }
}
