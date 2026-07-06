/// Where a control command executes (was `SocketCommandExecutionPolicy` +
/// the `socketWorkerV2Methods`/`mainThreadCallableSocketWorkerV2Methods`
/// tables on `TerminalController`). `init(forMethod:)` classifies v2 methods;
/// `init(forV1Command:)` classifies v1 space-delimited commands.
///
/// An isolation-intent value: the dispatcher consults it to decide whether a
/// method runs on the main actor or stays on the socket-worker thread. The
/// main-thread-callable refinement only exists for worker-lane methods, so it
/// is an associated value of that case rather than a separate table.
public enum ControlCommandExecutionPolicy: Sendable, Equatable {
    /// The command must run on the main actor (UI/window/workspace state).
    case mainActor
    /// The command runs on the socket-worker thread (blocking or long-running
    /// work that must not occupy the main actor). `mainThreadCallable` marks
    /// the pure, non-blocking probes that may also be invoked synchronously
    /// from the main thread.
    case socketWorker(mainThreadCallable: Bool)

    /// Classifies a method: every `vm.`- and `remotes.`-prefixed method and the
    /// fixed socket-worker set run on the worker; everything else runs on the
    /// main actor.
    ///
    /// `remotes.*` (the `cmux remotes` device-registry verbs) make blocking,
    /// authenticated web API calls just like `vm.*`, so they must stay off the
    /// main actor; a prefix match keeps the three verbs in lockstep without
    /// listing each.
    ///
    /// - Parameter method: The trimmed method name.
    public init(forMethod method: String) {
        if method.hasPrefix("vm.") || method.hasPrefix("remotes.")
            || Self.socketWorkerMethods.contains(method) {
            self = .socketWorker(
                mainThreadCallable: Self.mainThreadCallableSocketWorkerMethods.contains(method)
            )
        } else {
            self = .mainActor
        }
    }

    /// Classifies a v1 (space-delimited) command: the fixed worker-lane set
    /// runs on the socket-worker thread; everything else runs on the main
    /// actor.
    ///
    /// The v2 namespace prefix rules (`vm.`, `remotes.`) deliberately do not
    /// apply here — they are v2 method namespaces, and a v1 token that happens
    /// to contain a dot must not be routed off the main lane by accident.
    ///
    /// - Parameter command: The v1 command token, lowercased by the dispatcher
    ///   (`processCommand` lowercases before dispatching, and this initializer
    ///   expects the same normalization).
    public init(forV1Command command: String) {
        if Self.socketWorkerV1Commands.contains(command) {
            self = .socketWorker(
                mainThreadCallable: Self.mainThreadCallableSocketWorkerV1Commands.contains(command)
            )
        } else {
            self = .mainActor
        }
    }

    /// True when the command runs on the socket-worker thread.
    public var runsOnSocketWorker: Bool {
        if case .socketWorker = self { return true }
        return false
    }

    /// Methods that run on the socket-worker thread instead of the main actor.
    /// Internal (not private) so the package tests can pin the exact set.
    static let socketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "auth.status",
        "auth.sign_in_url",
        "auth.begin_sign_in",
        "auth.sign_out",
        "feedback.submit",
        "feed.push",
        "feed.permission.reply",
        "feed.question.reply",
        "feed.exit_plan.reply",
        "browser.download.wait",
        "browser.profiles.list",
        "browser.profiles.create",
        "browser.profiles.rename",
        "browser.profiles.clear",
        "browser.profiles.delete",
        "browser.import.cookies",
        "mobile.attach_ticket.create",
        // `mobile.terminal.set_font` only validates params and emits a
        // `terminal.set_font` push event via thread-safe MobileHostService
        // statics (no main-actor UI access), so it runs on the socket worker
        // like the other mobile data-plane verbs. Without this entry the policy
        // routes it to the main-actor processV2Command switch, which lacks the
        // case, and the control socket returns method_not_found.
        "mobile.terminal.set_font",
        "system.top",
        "system.memory",
        // `surface.read_text` reads a terminal's visible or full-scrollback
        // text and formats it (line tailing, candidate scoring, base64
        // encoding). On the main actor that formatting stalls the run loop
        // under heavy agent load
        // (https://github.com/manaflow-ai/cmux/issues/5757), so it runs on
        // the worker lane: only the routing resolution and the Ghostty FFI
        // capture take a minimal `v2MainSync` hop while the formatting stays
        // off the main actor. The @MainActor ControlCommandCoordinator seam
        // cannot host that split, so the method stays app-side like the
        // browser.* lane (`TerminalController.v2SurfaceReadText`). NOT
        // mainThreadCallable: the whole point is that the multi-MB formatting
        // never runs inline on the main thread, and no in-process main-thread
        // caller needs it.
        "surface.read_text",
        // `workspace.env` is a read that resolves a workspace and copies its
        // env dictionary behind a `v2MainSync` hop, so it runs on the worker
        // lane like the other workspace reads below.
        "workspace.env",
        "workspace.remote.pty_sessions",
        "workspace.remote.pty_close",
        "workspace.remote.pty_detach",
        "workspace.remote.pty_bridge",
        "workspace.remote.pty_resize",
        "remote.tmux.sessions",
        "remote.tmux.attach",
        "remote.tmux.detach",
        "remote.tmux.state",
        "remote.tmux.mirror",
        "remote.tmux.window",
        "sidebar.custom.validate",
        "sidebar.custom.reload",
        "sidebar.custom.select",
        "sidebar.custom.open",
        // debug.sidebar.simulate_drag intentionally runs on the socket worker
        // so its Thread.sleep between drag-state ticks doesn't block the main
        // actor (which still owns the SidebarDragState mutations via
        // v2MainSync). Running on .mainActor would deadlock the UI for the
        // entire simulation, defeating the profiling workload.
        "debug.sidebar.simulate_drag",
        // Browser automation methods that wait on page JavaScript, WebKit
        // cookies, or capture callbacks run on the socket worker: on the main
        // actor they block SwiftUI updates for their full duration, and on a
        // not-yet-mounted webview that is a starvation deadlock (the JS can't
        // run until SwiftUI mounts the webview, which can't happen while the
        // handler holds the main thread). UI/model access inside the handlers
        // stays on main via v2MainSync.
        "browser.navigate",
        "browser.back",
        "browser.forward",
        "browser.reload",
        "browser.snapshot",
        "browser.eval",
        "browser.wait",
        "browser.click",
        "browser.dblclick",
        "browser.hover",
        "browser.focus",
        "browser.type",
        "browser.fill",
        "browser.press",
        "browser.keydown",
        "browser.keyup",
        "browser.check",
        "browser.uncheck",
        "browser.select",
        "browser.scroll",
        "browser.scroll_into_view",
        "browser.get.text",
        "browser.get.html",
        "browser.get.value",
        "browser.get.attr",
        "browser.get.count",
        "browser.get.box",
        "browser.get.styles",
        "browser.is.visible",
        "browser.is.enabled",
        "browser.is.checked",
        "browser.find.role",
        "browser.find.text",
        "browser.find.label",
        "browser.find.placeholder",
        "browser.find.alt",
        "browser.find.title",
        "browser.find.testid",
        "browser.find.first",
        "browser.find.last",
        "browser.find.nth",
        "browser.highlight",
        "browser.screenshot",
        "browser.frame.select",
        "browser.dialog.accept",
        "browser.dialog.dismiss",
        "browser.cookies.get",
        "browser.cookies.set",
        "browser.cookies.clear",
        "browser.storage.get",
        "browser.storage.set",
        "browser.storage.clear",
        "browser.console.list",
        "browser.console.clear",
        "browser.errors.list",
        "browser.state.save",
        "browser.state.load",
        "browser.addinitscript",
        "browser.addscript",
        "browser.addstyle",
        // The v2 surface-telemetry twins of the v1 report family. Parse and
        // response encoding run on the worker; each body crosses to the main
        // actor exactly once (the resolution + write + ref minting hop), so
        // the deliberately-synchronous first relay `surface.report_tty`
        // (cmux-zsh-integration.zsh `_cmux_report_tty_once`) still returns
        // only after the TTY registration is visible to later commands.
        "surface.report_pwd",
        "surface.report_shell_state",
        "surface.report_tty",
        "surface.ports_kick",
        // The notification-create family and workspace.set_auto_title run the
        // same single-hop worker shape (parse/bridge/encode on the worker, one
        // v2MainSync around the shared main-actor dispatch). The hop stays
        // synchronous so the reply is written only after the hop body ran —
        // matching the legacy main-lane ordering exactly. NOTE: that is NOT
        // an unconditional read-your-write guarantee for create-then-list:
        // with notification policy hooks configured, the store defers the
        // apply into a Task past addNotification's return
        // (TerminalNotificationStore.addNotification), so the create reply
        // can precede store visibility — identical to baseline; do not build
        // on create-then-list ordering. `notification.reconcile` is NOT
        // here: it is a mobile-host data-plane verb (v2MobileDispatch), not
        // a control-socket method, so no execution policy applies to it.
        "notification.create",
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.create_for_caller",
        "workspace.set_auto_title",
        // The v2 resolution reads (tranche D of issue #5757) — the implicit
        // handle-normalization reads nearly every CLI invocation pays 1-3 of.
        // Their nonisolated coordinator bodies
        // (ControlCommandCoordinator.handleSocketWorkerV2) take ONE
        // controlResolveOnMain hop (known-ref refresh + routing resolution +
        // snapshot witness + ref minting in payload order) and build/encode
        // the JSON reply on the worker. None are focus-intent.
        "surface.list",
        "surface.current",
        "workspace.list",
        "workspace.current",
        "window.list",
        "window.current",
        "window.displays",
        "pane.list",
        "pane.surfaces",
        "system.identify",
        "system.tree",
        // The v2 send lane (tranche E of issue #5757): text/key parsing and
        // reply shaping run on the worker; the narrow hop resolves the target,
        // injects the input on main (Ghostty surface input is main-bound
        // AppKit/FFI), runs forceRefresh, and mints the success refs. The
        // reply is load-bearing (queued/input_queue_full/process_exited drive
        // caller retry), so the hop stays synchronous. Not focus-intent:
        // sending input never activates or reselects anything.
        "surface.send_text",
        "surface.send_key",
    ]

    /// Socket-worker methods that are also safe to invoke from the main
    /// thread. The invariant is deadlock-freedom, not zero cost: a member's
    /// body must contain no semaphore or cross-thread wait (its `v2MainSync`
    /// hops collapse to inline calls for a main-thread caller), but bounded
    /// synchronous work may still run inline on the caller's thread, exactly
    /// as the legacy main-lane dispatch did. `system.ping`/
    /// `system.capabilities` are pure probes; the surface-telemetry twins,
    /// the notification-create family, and workspace.set_auto_title are one
    /// inline-collapsing hop each (cmuxTests drive workspace.set_auto_title
    /// and notification.create_for_caller through handleSocketLine on the
    /// main actor). Internal (not private) so the package tests can pin the
    /// subset invariant.
    static let mainThreadCallableSocketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "surface.report_pwd",
        "surface.report_shell_state",
        "surface.report_tty",
        "surface.ports_kick",
        "notification.create",
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.create_for_caller",
        "workspace.set_auto_title",
        // The v2 resolution reads: non-blocking single-hop snapshot reads
        // whose hop collapses inline on a main-thread caller, so they are
        // safe by construction — and cmuxTests drive them through
        // handleSocketLine on the main actor
        // (AppDelegateIssue2907RoutingTests et al).
        "surface.list",
        "surface.current",
        "workspace.list",
        "workspace.current",
        "window.list",
        "window.current",
        "window.displays",
        "pane.list",
        "pane.surfaces",
        "system.identify",
        "system.tree",
        // The v2 send lane (tranche E): one narrow, non-blocking hop each
        // (resolve target + inject input + forceRefresh), so an inline
        // main-thread run is exactly the legacy main-lane dispatch.
        // surface.send_text is REQUIRED to be callable: the feed send-text
        // path (AppDelegate.handleFeedRequestSendText) drives it through
        // handleSocketLine on the main thread. surface.send_key shares the
        // identical body shape, so an asymmetric policy would only invite
        // drift.
        "surface.send_text",
        "surface.send_key",
    ]

    /// The v1 sidebar telemetry family, whose worker-lane bodies
    /// (`ControlCommandCoordinator.handleSidebarTelemetryV1`) parse/validate/
    /// format on the worker and either enqueue their mutation on the ordered
    /// `TerminalMutationBus` (zero main hops) or cross to the main actor for
    /// one narrow resolution/read hop. Internal (not private) so the package
    /// tests can pin the exact set.
    static let sidebarTelemetryV1Commands: Set<String> = [
        // Status / metadata entries (parse + bus enqueue; lists are one read hop).
        "set_status",
        "report_meta",
        "report_meta_block",
        "clear_status",
        "clear_meta",
        "clear_meta_block",
        "list_status",
        "list_meta",
        "list_meta_blocks",
        // Agent PID / lifecycle / hibernation.
        "set_agent_pid",
        "set_agent_lifecycle",
        "agent_hibernation",
        "clear_agent_pid",
        // Log / progress.
        "log",
        "clear_log",
        "list_log",
        "set_progress",
        "clear_progress",
        // Reports (git branch / PR / ports / pwd / shell state / tty / kick).
        "report_git_branch",
        "clear_git_branch",
        "report_pr",
        "report_review",
        "clear_pr",
        "report_pr_action",
        "report_ports",
        "clear_ports",
        "report_pwd",
        "report_shell_state",
        "report_tty",
        "ports_kick",
    ]

    /// The v1 notification family, whose worker-lane bodies live on
    /// `TerminalController`: parse/format on the worker; `notify_target_async`
    /// and `clear_notifications` are pure mutation-bus enqueues (zero main
    /// hops, hooks nohup them and discard the reply); the synchronous
    /// notify/list verbs keep one `v2MainSync` hop because their replies
    /// depend on tab/surface resolution or the delivered store state.
    /// Internal (not private) so the package tests can pin the exact set.
    static let notificationV1Commands: Set<String> = [
        "notify",
        "notify_surface",
        "notify_target",
        "notify_target_async",
        "list_notifications",
        "clear_notifications",
    ]

    /// The v1 terminal-read family (tranche C): `read_screen` is the v1 twin
    /// of `surface.read_text` — the Ghostty FFI capture takes one minimal
    /// `v2MainSync` hop and the (possibly multi-MB) tail/merge/base64
    /// formatting runs on the worker. Internal (not private) so the package
    /// tests can pin the exact set.
    static let terminalReadV1Commands: Set<String> = [
        "read_screen",
    ]

    /// The v1 resolution-read family (tranche D): the v1 twins of the v2
    /// resolution reads. Nonisolated `TerminalController` bodies take one
    /// `v2MainSync` snapshot hop and format their reply lines on the worker.
    /// Internal (not private) so the package tests can pin the exact set.
    static let resolutionReadV1Commands: Set<String> = [
        "list_windows",
        "current_window",
        "list_workspaces",
        "list_surfaces",
        "current_workspace",
    ]

    /// The v1 terminal-send family (tranche E): nonisolated
    /// `TerminalController` bodies whose escape-sequence unescaping, arg
    /// splitting, and error-string mapping run on the worker around one
    /// narrow v2MainSync hop (resolve target + inject input + forceRefresh).
    /// `send_workspace` is DEBUG-only app-side; in Release its worker case
    /// replies with the legacy unknown-command error (the
    /// debug.sidebar.simulate_drag precedent). Internal (not private) so the
    /// package tests can pin the exact set.
    static let terminalSendV1Commands: Set<String> = [
        "send",
        "send_key",
        "send_surface",
        "send_key_surface",
        "send_workspace",
    ]

    /// v1 commands that run on the socket-worker thread instead of the main
    /// actor: `ping` (the dispatcher's former hard-coded fast path) plus the
    /// sidebar telemetry, notification, terminal-read, resolution-read, and
    /// terminal-send families. Internal (not private) so the package tests
    /// can pin the exact set.
    static let socketWorkerV1Commands: Set<String> =
        sidebarTelemetryV1Commands
            .union(notificationV1Commands)
            .union(terminalReadV1Commands)
            .union(resolutionReadV1Commands)
            .union(terminalSendV1Commands)
            .union(["ping"])

    /// Worker-lane v1 commands that are also safe to invoke from the main
    /// thread. Must be a subset of ``socketWorkerV1Commands``, and is
    /// deliberately an EXPLICIT enumeration rather than an alias of the
    /// worker set: a future worker-lane verb must opt in here, so the v1
    /// invalid_dispatch guard stays meaningful by construction (the package
    /// tests pin both sets exactly).
    ///
    /// The invariant a member promises is deadlock-freedom, not zero cost:
    /// its body contains no semaphore or cross-thread wait — parse and bus
    /// enqueues never block, and the narrow `v2MainSync` hops collapse to
    /// inline calls on main — but bounded synchronous work still runs inline
    /// on a main-thread caller (e.g. `set_agent_lifecycle`'s vault-registry
    /// config-file read), exactly as the legacy main-lane dispatch did.
    /// In-process main-thread callers and cmuxTests exercise these verbs via
    /// `handleSocketLine` on the main actor.
    ///
    /// `read_screen` is deliberately NOT here (matching `surface.read_text`):
    /// its formatting can be multi-MB, running it inline on a main-thread
    /// caller defeats the off-main split, and no in-process main-thread
    /// caller uses it.
    static let mainThreadCallableSocketWorkerV1Commands: Set<String> = [
        "ping",
        "set_status",
        "report_meta",
        "report_meta_block",
        "clear_status",
        "clear_meta",
        "clear_meta_block",
        "list_status",
        "list_meta",
        "list_meta_blocks",
        "set_agent_pid",
        "set_agent_lifecycle",
        "agent_hibernation",
        "clear_agent_pid",
        "log",
        "clear_log",
        "list_log",
        "set_progress",
        "clear_progress",
        "report_git_branch",
        "clear_git_branch",
        "report_pr",
        "report_review",
        "clear_pr",
        "report_pr_action",
        "report_ports",
        "clear_ports",
        "report_pwd",
        "report_shell_state",
        "report_tty",
        "ports_kick",
        // The v1 notification family (tranche B2): notify_target_async and
        // clear_notifications are pure bus enqueues; the synchronous verbs
        // are one inline-collapsing hop each.
        "notify",
        "notify_surface",
        "notify_target",
        "notify_target_async",
        "list_notifications",
        "clear_notifications",
        // The v1 resolution reads (tranche D): non-blocking single-hop
        // snapshot reads whose hop collapses inline on a main-thread caller,
        // so they are safe by construction.
        "list_windows",
        "current_window",
        "list_workspaces",
        "list_surfaces",
        "current_workspace",
        // The v1 sends (tranche E): one narrow, non-blocking hop each.
        // send_workspace is REQUIRED to be callable: cmuxTests drive it
        // through handleSocketLine on the main actor
        // (TerminalAndGhosttyTests' daemon cold-send regression); the rest
        // share the identical body shape.
        "send",
        "send_key",
        "send_surface",
        "send_key_surface",
        "send_workspace",
    ]
}
