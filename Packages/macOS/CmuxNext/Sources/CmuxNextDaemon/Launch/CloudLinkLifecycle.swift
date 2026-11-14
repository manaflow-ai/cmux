public import Foundation
import os

/// This Mac's `cmux link` across a Cloud session (cx-rtipa S3): the app's
/// `CloudService` drives it at sign-in, connect, sign-out, session end and
/// policy changes; the session state comes in as closures. One link task
/// runs at a time, a session end waits for it, and an ensure of an ended
/// session does nothing or stops what it started.
@MainActor
public final class CloudLinkLifecycle {
    /// This Mac's `cmux link` for the app server path (cx-rtipa S3); nil on
    /// the legacy path and in an untagged DEBUG build.
    private let linkLauncher: (any CloudLinkLaunching)?
    /// The running ensure (one at a time; ``ensureLinkReport()``).
    private var linkTask: Task<JSONValue, Never>?
    /// Bumped when a session ends: an ensure of an older one does nothing.
    private var linkGeneration: UInt64 = 0
    /// The Stack user the link was last started for.
    private var linkUser: String?
    /// The selected team/mesh scope. A team switch is a new link even when
    /// the Stack user remains signed in.
    private var linkTeam: String?
    /// Set while a session ends (sign-out, session end): no ensure runs.
    private var linkEnding = false

    private let installID: @MainActor () async -> String?
    /// Cloud may be called: allowed for this build, not turned off by
    /// policy, signed in. Set by the owner after its own init (it reads the
    /// owner); until then nothing is available.
    public var isAvailable: @MainActor () -> Bool = { false }
    public var isSignedIn: @MainActor () -> Bool = { false }
    /// The app's verified local daemon connection.
    private let connection: @MainActor () -> DaemonConnection?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")

    public init(launcher: (any CloudLinkLaunching)?, installID: @escaping @MainActor () async -> String?,
                connection: @escaping @MainActor () -> DaemonConnection?) {
        self.linkLauncher = launcher
        self.installID = installID
        self.connection = connection
    }

    /// A session began for `user`: another person's link never keeps
    /// running for this one, and ensures may run again.
    /// Returns whether it ended another user's link (Switch Account), so the
    /// owner drops that account's work too.
    @discardableResult
    public func sessionBegan(user: String?, team: String? = nil) async -> Bool {
        let switched = linkUser.map { $0 != user || linkTeam != team } ?? false
        if switched { await endLink(final: true) }
        linkEnding = false
        linkUser = user
        linkTeam = team
        return switched
    }

    /// A sign-out starts: no ensure starts until the session's final
    /// ``endLink(final:)``.
    public func beginEnding() { linkEnding = true }

    /// Cloud was turned off by policy: no ensure of before the policy runs
    /// on, and the link stops (the session stays, so nothing is archived).
    public func policyTurnedOff() {
        linkGeneration &+= 1
        let running = linkTask
        linkTask = nil
        // task-owner: one teardown hop; stopLink() is idempotent
        Task { [weak self] in
            _ = await running?.value
            await self?.stopLink()
        }
    }

    /// Starts this Mac's `cmux link` unless one of this build runs, as the
    /// signed-in install, and tells the daemon when it started, so the Cloud
    /// server sees it before the connect (cx-rtipa S3). A failure is logged;
    /// the connect then answers that the helper is not running.
    public func ensureLink() async { _ = await ensureLinkReport() }

    /// ``ensureLink()`` with what happened, for `debug.cloud.link_ensure` on
    /// the debug socket (DEBUG builds): the ensure status and pid, and when the link started,
    /// how many app servers `apps-link-changed` told (or its refusal).
    public func ensureLinkReport() async -> JSONValue {
        guard linkLauncher != nil else { return .object(["error": .string("not the app server link path")]) }
        guard isAvailable() else { return .object(["error": .string("Cloud is not available")]) }
        guard !linkEnding else { return .object(["error": .string("the Cloud session is ending")]) }
        // One link task: an ensure waits for the one before it.
        let previous = linkTask
        let generation = linkGeneration
        let task = Task { [weak self] () -> JSONValue in
            _ = await previous?.value
            guard let self else { return .null }
            return await self.runEnsure(linkLauncher, generation: generation)
        }
        linkTask = task
        return await task.value
    }

    /// One ensure. Nothing once a sign-out or a session end started
    /// (`linkGeneration` moved); a link that started meanwhile is stopped.
    private func runEnsure(_ linkLauncher: (any CloudLinkLaunching)?, generation: UInt64) async -> JSONValue {
        guard generation == linkGeneration, isSignedIn() else { return .object(["error": .string("signed out")]) }
        guard let linkLauncher else { return .object(["error": .string("link unavailable")]) }
        guard let install = await installID() else { return .object(["error": .string("no install")]) }
        do {
            let ensured = try await linkLauncher.ensure(install: install)
            if generation != linkGeneration {
                await linkLauncher.stop(install: install)
                return .object(["error": .string("signed out during the ensure")])
            }
            var report: [String: JSONValue] = ["status": .string(ensured.status), "pid": ensured.pid.map { .number(Double($0)) } ?? .null]
            if ensured.status != "running" { report["link_changed"] = await notifyLinkChanged() }
            return .object(report)
        } catch {
            logger.error("cloud link ensure failed: \(String(describing: error), privacy: .public)")
            return .object(["error": .string(String(describing: error))])
        }
    }

    /// The session ends (sign-out, or the session ended elsewhere): no new
    /// ensure starts, the running one is waited for, the link stops, and the
    /// install's key and peers go into the archive.
    /// `final`: the session's last call (the signed-out branch); only it
    /// lets ensures run again.
    public func endLink(final: Bool) async {
        linkEnding = true
        linkGeneration &+= 1
        let running = linkTask
        linkTask = nil
        _ = await running?.value
        let install = await installID()
        await stopLink(install: install)
        await linkLauncher?.archive(install: install)
        linkUser = nil
        linkTeam = nil
        if final { linkEnding = false }
    }

    /// Stops this Mac's `cmux link` and tells the daemon. `install` only
    /// names the link in a failure log.
    public func stopLink(install: String? = nil) async {
        await linkLauncher?.stop(install: install)
        await notifyLinkChanged()
    }

    /// Sends `apps-link-changed` on the app's verified daemon connection;
    /// the daemon's answer (`{servers}`) or the refusal.
    @discardableResult
    private func notifyLinkChanged() async -> JSONValue {
        guard let connection = connection() else { return .object(["error": .string("not connected")]) }
        do {
            let answer = try await connection.request(AppsLinkChangedRequest())
            logger.info("apps-link-changed: \(String(describing: answer), privacy: .public)")
            return answer
        } catch {
            logger.error("apps-link-changed failed: \(String(describing: error), privacy: .public)")
            return .object(["error": .string(String(describing: error))])
        }
    }
}
