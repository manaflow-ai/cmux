public import CmuxNextCloud
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Signing in enrolls this Mac on the hub (the rule of the sign-in, in the code since 2026-11-14). acpmux decides
/// and does all of it (`server/sign_in_follow.rs`: when to enroll, its retry, recording the account
/// signing out before anything waits, and the leave of only a join signing in made). This only
/// tells the app's acpmux who is signed in now (`userId`, or none) and who was before (`previous`).
/// The access token goes only in that request on the local acpmux socket, never in argv, the
/// environment or a log. Signing in publishes the person before its token can be read (its team
/// refresh): the person is reported once that sign-in has finished (``signedInPerson``), and acpmux
/// keeps an enroll with no token pending until a report brings one. A report acpmux did not take
/// (its line not yet the person's, as in a launch whose acpmux outlived the one before, or acpmux not up
/// yet), or a signed-in one that went with no token (its mint failed), goes again on a short backoff
/// until one is taken whole (cloud-carrier-ssh-failover, 2026-11-26: the app stayed signed in and acpmux
/// had no join, because the one report of that launch was lost and nothing sent it again).
@MainActor
public final class CloudSignInEnroll {
    /// One change to the app's acpmux; true when it took it.
    typealias Send = @MainActor (_ params: [String: Any]) async -> Bool
    /// Records with the acpmux CLI, which needs no daemon, that `userId` signed out at `signedOutAt`
    /// (Unix ms): acpmux drops an intent from before that account's next sign-in.
    typealias RecordLeave = @MainActor (_ userId: String, _ signedOutAt: Int64) async -> Bool

    public static let capability = "machine-signed-in-v1"
    /// About seven minutes of tries, then none until the next change or acpmux's return.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15),
                                          .seconds(30), .seconds(60), .seconds(60), .seconds(120), .seconds(120)]
    static let method = "_acpmux/machine_signed_in"

    /// Who is signed in now; `.none` while the session is still being read.
    private let person: @MainActor @Sendable () -> String??
    private let accessToken: @MainActor () async -> String?
    private let send: Send
    private let recordLeave: RecordLeave
    private let extra: [String: String]
    /// The change sent last.
    private var last: (userId: String?, previous: String?)?
    /// One more for each change and each return of acpmux: a retry of an older one stops.
    private var generation = 0
    /// The waits between tries of one change acpmux did not take whole.
    private let retryDelays: [Duration]
    private var work: Task<Void, Never>?
    /// The wait before the next try of a change acpmux did not take whole.
    private let retryTimer = DemandTimer(owner: "cloud.sign-in-enroll.retry")
    /// A try is waiting on ``retryTimer`` (tests: ``settled()`` waits for it too).
    private var retrying = false
    private var following: Task<Void, Never>?

    init(person: @escaping @MainActor @Sendable () -> String??, accessToken: @escaping @MainActor () async -> String?,
         hub: String?, buildTag: String?, recordLeave: @escaping RecordLeave,
         retryDelays: [Duration] = CloudSignInEnroll.retryDelays, send: @escaping Send) {
        self.person = person
        self.retryDelays = retryDelays
        self.accessToken = accessToken
        self.recordLeave = recordLeave
        self.send = send
        var extra: [String: String] = [:]
        if let hub, !hub.isEmpty { extra["hub"] = hub }
        if let buildTag, !buildTag.isEmpty { extra["buildTag"] = buildTag }
        self.extra = extra
    }

    /// Follows the signed-in person for the app's life (its owner, the app's services, lives as long).
    public func follow() {
        guard following == nil else { return }
        let person = person
        // task-owner: the follow, for the app's life (the owner never goes before the app ends).
        following = Task { [weak self] in
            for await next in ObservationStream(person) {
                if case let .some(userId) = next { self?.changed(to: userId) }
            }
        }
    }

    /// The app's acpmux connection is up again: the last change goes once more, taken or not. A
    /// restarted acpmux lost the enroll it took (the token is never on disk); one that did not
    /// restart changes nothing for it (`sign_in_follow.rs`).
    public func acpmuxReturned() {
        guard let last else { return }
        submit(last.userId, previous: last.previous)
    }

    /// Waits for every change so far (tests).
    func settled() async {
        let sending = work
        await sending?.value
        guard retrying || work != sending else { return }
        // A retry still waiting: its timer fires (tests wait zero), then the try it sends.
        if retrying { await Task.yield() }
        await settled()
    }

    func changed(to userId: String?) {
        if let last, last.userId == userId { return }
        let previous = last?.userId
        last = (userId, previous)
        // The CLI records the account signing out even with acpmux down; acpmux records it too.
        if let previous, previous != userId {
            let recordLeave = recordLeave
            let signedOutAt = Int64(Date().timeIntervalSince1970 * 1000)
            // task-owner: one CLI run that writes the departing account; ends with it (bounded by its deadline).
            Task { _ = await recordLeave(previous, signedOutAt) }
        }
        submit(userId, previous: previous)
    }

    /// Sends a change after the one before. `attempt` 0 is a new change (or acpmux's return), which ends
    /// any retry still waiting; a send acpmux did not take whole tries again after `retryDelays[attempt]`.
    private func submit(_ userId: String?, previous: String?, attempt: Int = 0) {
        if attempt == 0 {
            generation += 1
            retryTimer.cancel()
            retrying = false
        }
        let mine = generation
        let before = work
        // task-owner: one change's request, after the one before; ends with it.
        work = Task { [weak self] in
            await before?.value
            guard let self, self.generation == mine else { return }
            let whole = await self.sendWhole(userId, previous: previous)
            guard !whole, self.generation == mine, attempt < self.retryDelays.count else { return }
            // One wait before the next try; a newer change cancels it (bounded by `retryDelays`).
            self.retrying = true
            self.retryTimer.schedule(after: self.retryDelays[attempt], reason: "sign-in report not taken") { @MainActor [weak self] in
                guard let self, self.generation == mine else { return }
                self.retrying = false
                self.submit(userId, previous: previous, attempt: attempt + 1)
            }
        }
    }

    /// One send of the change; true when acpmux took it, with a token when someone is signed in.
    private func sendWhole(_ userId: String?, previous: String?) async -> Bool {
        var params: [String: Any] = extra
        params["userId"] = userId.map { $0 as Any } ?? NSNull()
        params["previous"] = previous.map { $0 as Any } ?? NSNull()
        var withToken = false
        if userId != nil, let access = await accessToken(), !access.isEmpty {
            params["accessToken"] = access
            withToken = true
        }
        let taken = await send(params)
        return taken && (userId == nil || withToken)
    }

    /// Who is signed in, for ``follow()``: `.none` while the session is still being read, at launch
    /// (`restoring`) or in a sign-in that has not finished (`completingSignIn`, whose token cannot be
    /// read until its team refresh ends); `.some(nil)` signed out.
    nonisolated static func signedInPerson(restoring: Bool, completingSignIn: Bool, signedIn: Bool,
                                           userID: String?) -> String?? {
        guard !restoring, !completingSignIn else { return .none }
        guard signedIn else { return .some(nil) }
        return userID.map { .some($0) } ?? .none
    }
}

extension CloudSignInEnroll {
    /// ``CloudSignInEnroll`` over the app's acpmux (`environment`; nil with no acpmux, as in a mock
    /// agent host): each change is one short ``AcpmuxPersonLine``, sent only when it proved the person
    /// and the daemon serves ``CloudSignInEnroll/capability``. The hub is the platform origin the app
    /// selected (`CloudConfiguration.relayAPIBaseURL`). `windows`: the app's connection to acpmux's
    /// chat index, whose return (a restarted daemon answering) sends the last change again.
    ///
    /// The token is a cmux access token for the active team (`cmux auth token`'s, minted from this
    /// Mac's install `identity`), never the sign-in session's: the hub's machine routes take only a
    /// token with a team claim, and answered the session's with 401 `machine.unauthorized` on every
    /// sign-in (cloud-carrier-ssh-failover, 2026-11-15).
    public static func overAcpmux(auth: CloudAuth, identity: MacInstallIdentity, buildTag: String?,
                                  windows: AcpmuxChatWindows?,
                                  environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> CloudSignInEnroll {
        let hub = auth.configuration.relayAPIBaseURL().absoluteString
        let enroll = CloudSignInEnroll(person: { [weak auth] in
            guard let auth else { return .none }
            // The platform id: a machine record names its person by it, never by the Stack id.
            return signedInPerson(restoring: auth.isRestoring, completingSignIn: auth.coordinator.isLoading,
                                  signedIn: auth.isSignedIn, userID: auth.platformUserID)
        }, accessToken: { [weak auth] in await auth?.machineRoutesToken(identity: identity) }, hub: hub, buildTag: buildTag,
        recordLeave: { userId, signedOutAt in
            // `acpmux machine leave-intent`: the CLI writes it in the app's acpmux home, daemon or not.
            guard let environment = environment() else { return false }
            var variables = ProcessInfo.processInfo.environment
            variables.merge(environment.childEnvironment) { $1 }
            let command = AcpmuxPeerUpdateCommand(executable: environment.executable, environment: variables,
                                                  deadline: .seconds(45))
            return await command.run(["--json", "machine", "leave-intent", "--user-id", userId,
                                      "--signed-out-at", String(signedOutAt)]).status == 0
        }) { params in
            // `connectEnrolling`: an acpmux this launch never keyed (it outlived the app before, as across a
            // sign-out and relaunch) gets this launch's key, the way the consent line does, so the report proves.
            guard let environment = environment(),
                  case .success(let line) = await AcpmuxPersonLine.connectEnrolling(environment) else { return false }
            defer { line.close() }
            // Only a line that proved the person may enroll or leave; the daemon refuses any other.
            guard line.isPerson, line.capabilities.contains(capability) else { return false }
            return await line.call(method, params) != nil
        }
        windows?.followAvailability(enroll) { [weak enroll] in enroll?.acpmuxReturned() }
        return enroll
    }
}
