import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Darwin
import Testing

/// Owns each daemon a test launch ensured, including one whose first handshake never completed.
actor AppTestDaemonOwner {
    private let launcher: DaemonLauncher
    private var endpoints: Set<DaemonEndpoint> = []
    private var processes: [DaemonEndpoint: AcpmuxDaemonStop.Daemon] = [:]
    private var ensureFailed = false
    private var stopping = false
    private var ensures: [UUID: Task<DaemonEndpoint, any Error>] = [:]

    init(_ launcher: DaemonLauncher) { self.launcher = launcher }

    nonisolated var endpointProvider: DaemonConnection.EndpointProvider {
        { try await self.endpoint() }
    }

    private func endpoint() async throws -> DaemonEndpoint {
        guard !stopping else { throw CancellationError() }
        let id = UUID()
        // task-owner: one bounded ensure; both its caller and reap join it before dropping ownership
        let ensure = Task { try await self.ensureEndpoint() }
        // Keep every launch attempt registered until reap() has joined it. The caller may be
        // cancelled while ensureEndpoint() is still starting a daemon; removing it here lets
        // teardown report success and delete its state directory before that launch records its
        // ownership.
        ensures[id] = ensure
        return try await ensure.value
    }

    private func ensureEndpoint() async throws -> DaemonEndpoint {
        // A cancelled ensure can have detached its owner before stdout reports it. Let this
        // bounded attempt finish and record ownership; stop() joins its caller before reaping.
        let launcher = launcher
        let timer = PhaseTimer("daemon")
        do {
            let endpoint = try await launcher.endpointProvider()
            timer.mark("endpoint")
            record(endpoint)
            return endpoint
        } catch {
            ensureFailed = true
            throw error
        }
    }

    /// False preserves the caller's state directory for an owner whose exit is unconfirmed.
    @MainActor @discardableResult func stop(_ services: AppServices) async -> Bool {
        // task-owner: joined teardown; runs even when the test's task is already cancelled
        await Task { @MainActor in
            await services.daemon.shutdownConnectionAndWait()
            await services.windows.prepareForTermination()
            return await self.reap()
        }.value
    }

    @discardableResult func reap() async -> Bool {
        stopping = true
        // Reject new requests and join admitted ensures before taking the ownership census.
        for ensure in Array(ensures.values) { _ = try? await ensure.value }
        ensures.removeAll()
        var resolved = true
        if let running = await launcher.runningOwner() {
            record(running.endpoint)
        } else if ensureFailed {
            Issue.record("daemon ensure failed and its final owner could not be established; cleanup is incomplete")
            resolved = false
        }
        for endpoint in Array(endpoints) {
            let exited = await Self.reap(endpoint, process: processes[endpoint]) {
                let connection = DaemonConnection(endpoint: endpoint)
                do {
                    _ = try await connection.start()
                    // endTerminals uses its own socket and retains this identity. Close the
                    // subscribed connection first so EOF cannot start a replacement owner.
                    await connection.closeAndWait()
                    let reply = try await connection.shutdownDaemon(endTerminals: true)
                    return reply.accepted == true
                } catch {
                    await connection.closeAndWait()
                    throw error
                }
            }
            #expect(exited, "test daemon exit was not confirmed: \(String(describing: endpoint.pid)); preserving its state directory")
            if exited {
                endpoints.remove(endpoint)
                processes[endpoint] = nil
            } else { resolved = false }
        }
        return resolved
    }

    /// Remember the process while ensure's endpoint still belongs to the configured binary
    /// and socket. The audit token includes the kernel pid version: a recycled pid is never
    /// signalled, even if it changes between verification and the signal syscall.
    private func record(_ endpoint: DaemonEndpoint) {
        endpoints.insert(endpoint)
        guard processes[endpoint] == nil, let pid = endpoint.pid, pid > 1, pid != getpid(),
              endpoint.bridge == nil,
              let before = AcpmuxDaemonStop.kernelProcess(pid: pid),
              AcpmuxVersionHandoff.executablePath(pid: pid) == launcher.configuration.binary.resolvingSymlinksInPath().path,
              Self.listenerPID(socketPath: endpoint.socketPath) == pid,
              AcpmuxDaemonStop.kernelProcess(pid: pid) == before else { return }
        processes[endpoint] = before
    }

    /// A full listen backlog must not block ownership recording or teardown. If this
    /// nonblocking peer check cannot finish now, retain the endpoint without signal authority.
    private static func listenerPID(socketPath: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 1 ? pid : nil
    }

    /// Waits for this recorded process to exit without treating an unreadable identity as exit.
    /// The exit source is registered first; an already-gone PID is handled by its ESRCH check.
    static func waitForRecordedExit(pid: Int32, process: AcpmuxDaemonStop.Daemon,
                                    timeout: Duration = .seconds(60),
                                    currentProcess: @Sendable (Int32) -> AcpmuxDaemonStop.Daemon? = AcpmuxDaemonStop.kernelProcess(pid:)) async -> Bool {
        await AgentPaneProcessExit(pid: pid).event(within: timeout) {
            guard let current = currentProcess(pid) else { return nil }
            return current == process ? nil : true
        }
    }

    /// Shared with the failure-path regression: graceful shutdown may throw before identify.
    /// Its fallback uses the existing audit-token signaler and bounded TERM/KILL exit watches.
    static func reap(_ endpoint: DaemonEndpoint, process: AcpmuxDaemonStop.Daemon?,
                     grace: Duration = .seconds(10),
                     shutdown: @Sendable () async throws -> Bool) async -> Bool {
        guard let pid = endpoint.pid, pid > 1,
              let process, process.pid == pid else {
            // An endpoint without a verified kernel identity is retained for a later teardown.
            // Never send a graceful shutdown over its socket: it may now belong to a replacement
            // daemon that this test did not launch.
            return false
        }
        if (try? await shutdown()) == true {
            // Register the exit source before checking identity. A changed or missing identity
            // proves the recorded daemon is gone; the same identity leaves completion to the
            // kernel exit event, so PID reuse cannot be mistaken for a clean reap.
            return await waitForRecordedExit(pid: pid, process: process, timeout: .seconds(60))
        }
        return await stop(process, grace: grace, currentProcess: { pid in
            // Unreadable identity is not proof of exit. The retained audit token still lets
            // the kernel refuse a signal to any replacement process without a pid-only fallback.
            AcpmuxDaemonStop.kernelProcess(pid: pid) ?? process
        })
    }

    /// Test teardown only: SIGTERM, then SIGKILL when `daemon` outlives `grace`. True once it
    /// exited. Each signal goes through ``AcpmuxDaemonStop/signal(_:_:process:)``, so it reaches only
    /// the process `daemon` names (exit watch first, then the audit token); a pid that names
    /// another process now means `daemon` exited. The app itself never SIGKILLs acpmux (#28083).
    static func stop(_ daemon: AcpmuxDaemonStop.Daemon, grace: Duration,
                     currentProcess: @escaping @Sendable (Int32) -> AcpmuxDaemonStop.Daemon? = AcpmuxDaemonStop.kernelProcess(pid:)) async -> Bool {
        let pid = daemon.pid
        func send(_ signal: Int32) -> Bool? { AcpmuxDaemonStop.signal(daemon, signal, process: currentProcess) }
        var unsent = false
        let exited = await AgentPaneProcessExit(pid: pid).event(within: grace) {
            let answer = send(SIGTERM)
            unsent = answer != nil
            return answer
        }
        if exited || unsent { return exited }
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(5)) { send(SIGKILL) }
    }
}

/// cx-lle.6, Chrome's pinned tabs: a pinned browser tab keeps the page it was pinned on. The
/// app's Pin Tab records it on the daemon, the tab reports it after it browses away, and Back to
/// Pinned Page (`browser.resetPinnedTab`, tab menu, palette, `cmux browser back-to-pinned-page`)
/// takes the tab back there. Runs the app's action registry against a same-tree cmux-tui daemon,
/// as the tab menu and the CLI reach it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PinnedPageTests {
    static let pinnedPage = "https://mail.example.com/"
    static let elsewhere = "https://mail.example.com/inbox/42"

    @Test func backToPinnedPageReturnsAPinnedTabToThePageItWasPinnedOn() async throws {
        try await Self.withApp { services, connection in
            let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.handle)
            // A browser tab in the background: its page has not loaded here, so the daemon's record is the page.
            let surface = try await connection.newFrontendBrowserTab(url: Self.pinnedPage, engine: .webkit, in: pane, activate: false).surface
            try await Self.until({ services.daemon.store.tab(surface: surface) != nil }, report: { WindowStateReport.describe(services, surface: surface) })
            let tab = try #require(services.daemon.store.tab(surface: surface))
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
            let menu = services.registry.action(for: "browser.resetPinnedTab")
            #expect(menu != nil, "Back to Pinned Page is not an action")
            #expect(menu?.targetHidden?(target) == true, "an unpinned tab's menu offers Back to Pinned Page")

            // A pin that never lands says whether the handler refused, sent nothing, or the daemon failed it.
            var ran = false
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork { ran = services.registry.perform("palette.toggleTabPin", invocation: target) }
            }
            #expect(ran)
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            try await Self.until({ services.daemon.store.tab(surface: surface)?.pinned == true }, report: {
                "pin refusal \(refusal ?? "none"), pin work \(work.count), failures \(failures); " + WindowStateReport.describe(services, surface: surface)
            })
            // The tab browses away from the page it was pinned on.
            try await connection.updateFrontendBrowserTab(surface, url: Self.elsewhere)
            try await Self.until({ services.daemon.store.tab(surface: surface)?.url == Self.elsewhere }, report: { WindowStateReport.describe(services, surface: surface) })
            #expect(services.daemon.store.tab(surface: surface)?.pinnedURL == Self.pinnedPage)
            #expect(menu?.targetHidden?(target) == false, "the pinned tab's menu leaves out Back to Pinned Page")

            #expect(services.registry.perform("browser.resetPinnedTab", invocation: target))
            try await Self.until({ services.daemon.store.tab(surface: surface)?.url == Self.pinnedPage }, report: { WindowStateReport.describe(services, surface: surface) })
            #expect(services.daemon.store.tab(surface: surface)?.pinnedURL == Self.pinnedPage)
            #expect(menu?.targetHidden?(target) == true, "the tab is on its pinned page: nothing to go back to")
        }
    }

    /// Polls `condition` (the store follows the daemon's events) up to a
    /// deadline. A timeout is reported at the caller's line: which wait it was.
    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(20),
                      report: () -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out: \(report())", sourceLocation: sourceLocation)
    }

    /// The app's services on a fresh same-tree daemon, ready once the launch's restore is over and
    /// its first terminal shows.
    /// `heldKeyReplay`: where a creation hold's keys run again (the app's own unless a test passes another).
    static func withApp(heldKeyReplay: @escaping HeldKeyReplay = { event, _, _ in NSApp?.sendEvent(event) },
                        _ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        let timer = PhaseTimer("pinned")
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-pinned-\(UUID().uuidString.prefix(8))")
        var reaped = false
        defer { if reaped { try? FileManager.default.removeItem(at: root) } }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-pinned-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state"), exitWithProcess: ProcessInfo.processInfo.processIdentifier),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let owner = AppTestDaemonOwner(launcher)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]), heldKeyReplay: heldKeyReplay)
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: owner.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let watches = [timer.watch("restored") { services.windows.restored }, timer.watch("launch-over") { !services.windows.registry.isLaunching }]
        // Registered before restore can suspend or fail, including before the test body starts.
        defer {
            for watch in watches { watch.cancel() }
            for controller in services.windows.controllers { controller.window?.close() }
            for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
            let panels = NSApp.windows.filter { services.palette.owns($0) }
            services.palette.hide()
            for panel in panels { panel.close() }
        }
        let result: Result<Void, any Error>
        do {
            try await until({ services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }, within: .seconds(90))
            timer.mark("store-panes")
            // The launch is over: restore installed the saved windows (or gave up). The panes show
            // before that, and a restore that lands mid-body installs the saved registry over what
            // the body made: a workspace just moved to a new window lost that window (base8 at
            // 61ad0ed216f, MoveToNewWindowTests), and a save asked for then was still blocked
            // (SavedWindowsLaunchTests).
            try await until({ !services.windows.registry.isLaunching || services.windows.restoreGaveUp }, within: .seconds(90))
            timer.mark("launch-waited")
            // Actions reach tabs through the window's panes, which attach after the daemon's.
            try await until({ services.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(30))
            timer.mark("window-panes restored=\(services.windows.restored) launching=\(services.windows.registry.isLaunching)")
            result = .success(try await body(services, try #require(services.daemon.connection)))
            timer.mark("body")
        } catch { result = .failure(error); timer.mark("body-threw") }
        reaped = await owner.stop(services)
        timer.mark("stopped")
        try result.get()
    }
}
