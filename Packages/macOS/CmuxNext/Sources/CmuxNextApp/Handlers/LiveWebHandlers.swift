import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLiveCode
import CmuxNextSettings
import Foundation
import os

/// Edit cmux Live… and Stop Editing cmux Live (docs/cmux-next/hot-reload.md): the palette and
/// Settings > General face of `cmux live start|stop`, so a person finds Live Web Reload without
/// knowing the script. Leo (2026-11-05): "it should be like enableable in the GUI ... accessible,
/// visible, usable, and nice to use". Both run the bundled `cmux live` (one implementation with
/// the CLI and the `cmux-live` agent skill), off the main actor, and show the outcome as a toast.
@MainActor
enum LiveWebHandlers {
    static let startID: ActionID = "liveWeb.start"
    static let stopID: ActionID = "liveWeb.stop"
    static let swiftStartID: ActionID = "liveSwift.start"
    static let swiftStopID: ActionID = "liveSwift.stop"
    private static let toastID = "live-web"
    /// `start` may install the checkout's webviews packages first, then waits up to 60 s for the server.
    private static let startTimeout: Duration = .seconds(300)

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let bundled = context.services.bundledCLI
        Task { _ = await bundled.resolve() } // task-owner: none; one bounded file read whose answer bundled keeps
        let noCLI: @MainActor () -> String? = { bundled.known == nil ? LiveWebStrings.noCLI : nil }
        registry.bindEffect(startID, unavailable: noCLI, effect: { invocation in
            guard let cli = bundled.known else { return .refused(LiveWebStrings.noCLI) }
            let window = context.activeWindow?.window
            if let path = invocation["path"]?.stringValue, !path.isEmpty {
                show(LiveWebStrings.starting(path), in: window, duration: startTimeout)
                return .applied(result: {
                    await run(cli, ["live", "start", "--worktree", path], timeout: startTimeout,
                              done: LiveWebStrings.started(path), in: window)
                })
            }
            guard !registry.isCapturingRefusal else { return .refused(LiveWebStrings.pathRequired) }
            // The folder panel is this turn's visible change; its pick runs this action again with the path.
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.message = LiveWebStrings.chooseCheckout
            panel.prompt = LiveWebStrings.choose
            let completion: (NSApplication.ModalResponse) -> Void = { [weak registry] response in
                guard response == .OK, let url = panel.url else { return }
                _ = registry?.perform(startID, invocation: ActionInvocation(arguments: ["path": .string(url.path)], origin: .user))
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { panel.begin(completionHandler: completion) }
            return .done
        })
        registry.bindEffect(stopID, unavailable: noCLI, effect: { _ in
            guard let cli = bundled.known else { return .refused(LiveWebStrings.noCLI) }
            let window = context.activeWindow?.window
            show(LiveWebStrings.stopping, in: window, duration: .seconds(30))
            return .applied(result: {
                await run(cli, ["live", "stop"], timeout: .seconds(30), done: LiveWebStrings.stopped, in: window)
            })
        })
        bindSwift(into: registry, context: context, bundled: bundled)
    }

    /// Start / Stop Swift Live Mode (docs/cmux-next/live-code.md): `cmux live start|stop --swift`,
    /// detached, since the swap quits this app and starts the other build of its commit with every
    /// session. Leo (2026-11-05): "there should likely be a way to switch it on and off for when
    /// you're hot-building". Only a tagged DEV build switches; Labs > Live Code is user-only, so the
    /// person's own click sets it here and any other caller leaves it to the script's confirmation.
    private static func bindSwift(into registry: ActionRegistry, context: AppActionContext, bundled: BundledExecutable) {
        let environment = ProcessInfo.processInfo.environment
        let tagged = Bundle.main.bundleIdentifier?.hasPrefix("com.cmuxterm.app.debug.") == true
        let tree = environment["CMUXTERM_REPO_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
        let refusal: @MainActor (Bool) -> String? = { on in
            if bundled.known == nil { return LiveWebStrings.noCLI }
            if !tagged { return LiveWebStrings.swiftNotTagged }
            if tree == nil { return LiveWebStrings.swiftNoCheckout }
            return LiveCode.isLive == on ? (on ? LiveWebStrings.swiftAlreadyOn : LiveWebStrings.swiftAlreadyOff) : nil
        }
        for on in [true, false] {
            registry.bindEffect(on ? swiftStartID : swiftStopID, unavailable: { refusal(on) }, effect: { invocation in
                if let why = refusal(on) { return .refused(why) }
                guard let cli = bundled.known, let tree else { return .refused(LiveWebStrings.noCLI) }
                let window = context.activeWindow?.window
                let byPerson = invocation.origin == .user
                let settings = context.services.settings
                show(on ? LiveWebStrings.swiftStarting : LiveWebStrings.swiftStopping, in: window, duration: .seconds(20))
                return .applied(result: {
                    if byPerson { try? await settings?.setSetting(at: CmuxConfigSnapshot.liveCodePath, to: .bool(on), by: .user) }
                    var arguments = ["live", on ? "start" : "stop", "--swift", "--detach", "--worktree", tree]
                    if byPerson { arguments.append("--setting-done") }
                    return await run(cli, arguments, timeout: .seconds(30),
                                     done: on ? LiveWebStrings.swiftStarted : LiveWebStrings.swiftStopped, in: window)
                })
            })
        }
    }

    /// Runs `cmux <arguments>` and replaces the working toast with `done` or the command's error.
    private static func run(_ cli: URL, _ arguments: [String], timeout: Duration, done: String,
                            in window: NSWindow?) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let result = await runProcess(cli, arguments, timeout: timeout)
        guard let result, result.status == 0 else {
            let why = result.map { lastLine($0.stderr) ?? lastLine($0.stdout) ?? "exit \($0.status)" } ?? LiveWebStrings.didNotFinish
            let message = LiveWebStrings.failed(why)
            show(message, in: window, duration: .seconds(12))
            var failure = ActionWorkFailure(message)
            failure.shown = true // the toast above already says it
            return .failure(failure)
        }
        show(done, in: window, duration: .seconds(8))
        return .success(["output": .string(String(decoding: result.stdout, as: UTF8.self))])
    }

    @concurrent nonisolated private static func runProcess(_ cli: URL, _ arguments: [String], timeout: Duration) async -> ProcessResult? {
        try? await ProcessRunner.run(executable: cli, arguments: arguments, environment: nil, timeout: timeout,
                                     outputTailBytes: 64 * 1024, clock: ContinuousClock())
    }

    private nonisolated static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
    }

    private static func show(_ message: String, in window: NSWindow?, duration: Duration) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "live-web").info("live web: \(message, privacy: .public)")
            return
        }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message, duration: duration), in: window)
    }
}

enum LiveWebStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "LiveWeb", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    static var noCLI: String { text("liveWeb.noCLI", "This build does not include the cmux CLI.") }
    static var pathRequired: String { text("liveWeb.pathRequired", "Pass the cmux checkout to load from as path.") }
    static var chooseCheckout: String {
        text("liveWeb.chooseCheckout", "Choose a cmux checkout. cmux loads its web UI from it, and your saved edits show at once.")
    }
    static var choose: String { text("liveWeb.choose", "Edit Live") }
    static var stopping: String { text("liveWeb.stopping", "Going back to the built-in web UI…") }
    static var stopped: String { text("liveWeb.stopped", "cmux uses its built-in web UI again.") }
    static var didNotFinish: String { text("liveWeb.didNotFinish", "it did not finish in time") }

    static func starting(_ path: String) -> String {
        format("liveWeb.starting", "Starting the web UI dev server in %@…", (path as NSString).lastPathComponent)
    }

    static func started(_ path: String) -> String {
        format("liveWeb.started", "cmux now loads its web UI from %@. Save a file under webviews/ to see it change.",
               (path as NSString).lastPathComponent)
    }

    static func failed(_ why: String) -> String { format("liveWeb.failed", "Live Web Reload: %@", why) }

    static var swiftNotTagged: String {
        text("liveSwift.notTagged", "Swift live mode switches a tagged DEV build. A NIGHTLY has no live code build of its commit to restart into yet.")
    }
    static var swiftNoCheckout: String {
        text("liveSwift.noCheckout", "This build does not name the checkout it was built from, which builds its live code build.")
    }
    static var swiftAlreadyOn: String { text("liveSwift.alreadyOn", "Swift live mode is already on.") }
    static var swiftAlreadyOff: String { text("liveSwift.alreadyOff", "Swift live mode is off.") }
    static var swiftStarting: String { text("liveSwift.starting", "Starting Swift live mode…") }
    static var swiftStopping: String { text("liveSwift.stopping", "Stopping Swift live mode…") }
    static var swiftStarted: String {
        text("liveSwift.started", "cmux restarts into the live code build when it is ready (the first time it builds it), keeping every session.")
    }
    static var swiftStopped: String {
        text("liveSwift.stopped", "cmux restarts into the normal build, keeping every session.")
    }
}
