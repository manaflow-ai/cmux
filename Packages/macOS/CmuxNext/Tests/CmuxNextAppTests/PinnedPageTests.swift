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
    private var processes: [DaemonEndpoint: AcpmuxUnresponsiveWatch.Daemon] = [:]
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
        ensures[id] = ensure
        defer { ensures[id] = nil }
        return try await ensure.value
    }

    private func ensureEndpoint() async throws -> DaemonEndpoint {
        // A cancelled ensure can have detached its owner before stdout reports it. Let this
        // bounded attempt finish and record ownership; stop() joins its caller before reaping.
        let launcher = launcher
        do {
            let endpoint = try await launcher.endpointProvider()
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
              let before = AcpmuxUnresponsiveWatch.kernelProcess(pid: pid),
              AcpmuxVersionHandoff.executablePath(pid: pid) == launcher.configuration.binary.resolvingSymlinksInPath().path,
              Self.listenerPID(socketPath: endpoint.socketPath) == pid,
              AcpmuxUnresponsiveWatch.kernelProcess(pid: pid) == before else { return }
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

    /// Shared with the failure-path regression: graceful shutdown may throw before identify.
    /// Its fallback uses the existing audit-token signaler and bounded TERM/KILL exit watches.
    static func reap(_ endpoint: DaemonEndpoint, process: AcpmuxUnresponsiveWatch.Daemon?,
                     grace: Duration = .seconds(10),
                     shutdown: @Sendable () async throws -> Bool) async -> Bool {
        guard let pid = endpoint.pid, pid > 1 else { return false }
        if (try? await shutdown()) == true,
           await ProcessExit.exitEvent(pid: pid, within: .seconds(60), clock: ContinuousClock()) { return true }
        guard let process, process.pid == pid else {
            // An unverified live pid is evidence to preserve, never permission to signal it.
            return await ProcessExit.exitEvent(pid: pid, within: .seconds(1), clock: ContinuousClock())
        }
        let watch = AcpmuxUnresponsiveWatch(clock: ContinuousClock(), process: { pid in
            // Unreadable identity is not proof of exit. The retained audit token still lets
            // the kernel refuse a signal to any replacement process without a pid-only fallback.
            AcpmuxUnresponsiveWatch.kernelProcess(pid: pid) ?? process
        })
        return await watch.stop(process, grace: grace)
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

    /// The app's services on a fresh same-tree daemon, ready once restore made its first terminal.
    static func withApp(_ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
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
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: owner.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        // Registered before restore can suspend or fail, including before the test body starts.
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
            let panels = NSApp.windows.filter { services.palette.owns($0) }
            services.palette.hide()
            for panel in panels { panel.close() }
        }
        let result: Result<Void, any Error>
        do {
            try await until({ services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }, within: .seconds(90))
            // Actions reach tabs through the window's panes, which attach after the daemon's.
            try await until({ services.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(30))
            result = .success(try await body(services, try #require(services.daemon.connection)))
        } catch { result = .failure(error) }
        reaped = await owner.stop(services)
        try result.get()
    }
}
