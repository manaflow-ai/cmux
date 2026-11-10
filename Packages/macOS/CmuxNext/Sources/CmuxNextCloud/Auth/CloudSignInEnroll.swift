import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import os

/// Signing in enrolls this Mac on the hub (Leo: "Signing in enrolls the machine."). acpmux does the
/// work (`cli/cloud_join/enroll.rs`): this only tells the app's acpmux who signed in and who signed
/// out. The access token goes only in that request on the local acpmux socket, never in argv, the
/// environment or a log.
///
/// - Signed in (a sign-in, or the session restored at launch): `_acpmux/machine_enroll`, in the
///   background, with one retry after a failure. Sign-in never waits on it; a failure leaves this
///   Mac as it was.
/// - Signed out: first the account signing out is recorded with acpmux, durably and with no daemon
///   (``RecordLeave``, `acpmux machine leave-intent`), then `_acpmux/machine_leave_if_auto` with it
///   (`userId`), which leaves only a join signing in made for that account. A Mac joined with a
///   pair code or a join line, or for another account, stays joined. acpmux finishes a recorded
///   leave at its next start, before its relay, or at the next leave. Signed out at launch asks
///   again with no account (none is known then): acpmux leaves as the accounts it recorded, and
///   nothing else.
/// - A leave or an enroll acpmux did not answer (it was restarting) is sent again, for whoever is
///   signed in then, when the app's acpmux connection comes back (``acpmuxReturned()``): signed out,
///   the leave; signed in, the enroll.
/// - Another person: the leave, then the enroll. acpmux keeps the last person's leave itself: an
///   enroll that finds the last person's sign-in join finishes that leave first, and a revoke their
///   hub did not answer stays on disk until it does.
///
/// Event-driven (an ``ObservationStream`` of the signed-in person); its only wait is the retry's
/// ``Backoff``.
@MainActor
public final class CloudSignInEnroll {
    /// One request on a fresh line to the app's acpmux, which must serve `machine-enroll-v1`; nil when
    /// no acpmux answered, it lacks the capability, or the request failed.
    public typealias Call = @MainActor (_ method: String, _ params: [String: Any]) async -> [String: Any]?
    /// Records with acpmux, durably and with no daemon, that `userId` signs out; false when it was not
    /// recorded. acpmux keeps it, so a leave it never gets is still finished as that account's.
    public typealias RecordLeave = @MainActor (_ userId: String) async -> Bool

    /// Who is signed in, or that the session is still being read (nothing is decided then).
    enum Person: Equatable, Sendable {
        case restoring
        case signedOut
        case signedIn(String)
    }

    public static let capability = "machine-enroll-v1"
    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.signin-enroll")

    private let person: @MainActor @Sendable () -> Person
    private let accessToken: @MainActor () async -> String?
    private let call: Call
    private let recordLeave: RecordLeave
    private let extraParams: [String: String]
    /// The person the last change was for; nil signed out.
    private var current: String?
    /// The account the last sign-out was for, which a resent leave names; nil when none is known.
    private var signedOut: String?
    /// Whether the session has been read once since launch.
    private var decided = false
    /// A leave or an enroll acpmux did not answer: the current person's is sent when acpmux is back.
    private(set) var resendPending = false
    /// A request is waiting on acpmux now; `returnedMeanwhile`: the connection came back while it waited.
    private var waiting = false
    private var returnedMeanwhile = false
    /// The work for the changes so far, one after another.
    private var work: Task<Void, Never>?
    private var following: Task<Void, Never>?

    /// `hub`: the platform origin the app's `cmux machine add` mints on, when set. `buildTag`: a DEV
    /// build's tag, so its machine is named apart.
    public convenience init(auth: CloudAuth, hub: String?, buildTag: String?,
                            recordLeave: @escaping RecordLeave, call: @escaping Call) {
        self.init(person: { [weak auth] in
            guard let auth, !auth.isRestoring else { return .restoring }
            guard auth.isSignedIn else { return .signedOut }
            // Signed in with no user read yet is no person yet. The platform id: a machine record
            // names its person by it, never by the Stack id.
            return auth.platformUserID.map { .signedIn($0) } ?? .restoring
        }, accessToken: { [weak auth] in try? await auth?.tokens().access }, hub: hub, buildTag: buildTag,
                  recordLeave: recordLeave, call: call)
    }

    init(person: @escaping @MainActor @Sendable () -> Person, accessToken: @escaping @MainActor () async -> String?,
         hub: String?, buildTag: String?, recordLeave: @escaping RecordLeave = { _ in false }, call: @escaping Call) {
        self.person = person
        self.accessToken = accessToken
        self.recordLeave = recordLeave
        self.call = call
        var extra: [String: String] = [:]
        if let hub, !hub.isEmpty { extra["hub"] = hub }
        if let buildTag, !buildTag.isEmpty { extra["buildTag"] = buildTag }
        extraParams = extra
    }

    /// Follows the signed-in person for the app's life (its owner, the app's services, lives as long).
    /// Signed out at launch asks for the leave once more (acpmux leaves only a join signing in made).
    public func follow() {
        guard following == nil else { return }
        let person = person
        // task-owner: the follow, for the app's life (the owner never goes before the app ends).
        following = Task { [weak self] in
            for await next in ObservationStream(person) {
                self?.changed(to: next)
            }
        }
    }

    /// The app's acpmux connection is up again (a restarted daemon answers): a leave or enroll it did not
    /// answer is sent once more, after any change still running, for whoever is signed in by then.
    public func acpmuxReturned() {
        if waiting { returnedMeanwhile = true }
        guard resendPending else { return }
        resendPending = false
        let before = work
        // task-owner: the one resend, after the changes before it; ends with it.
        work = Task { [weak self] in
            await before?.value
            guard let self else { return }
            if let current { await enroll(userId: current) } else { await leaveIfAuto(userId: signedOut) }
        }
    }

    /// Waits for every change so far (tests).
    func settled() async { await work?.value }

    func changed(to person: Person) {
        let next: String?
        switch person {
        case .restoring: return
        case .signedOut: next = nil
        case let .signedIn(id): next = id
        }
        guard !decided || next != current else { return }
        // At launch, signed out: a sign-out whose leave never reached acpmux is asked again.
        let leave = decided ? current != nil : next == nil
        let leaving = decided ? current : nil
        if leave { signedOut = leaving }
        decided = true
        // This change sends its own requests: a resend still pending is not wanted any more.
        resendPending = false
        current = next
        let before = work
        // task-owner: one change's leave and enroll, after the previous change's; ends with them.
        work = Task { [weak self] in
            await before?.value
            guard let self else { return }
            if leave { await leaveIfAuto(userId: leaving) }
            if let next { await enroll(userId: next) }
        }
    }

    /// One request to acpmux; no reply marks a resend for when acpmux is back (``acpmuxReturned()``).
    private func send(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        waiting = true
        returnedMeanwhile = false
        let reply = await call(method, params)
        waiting = false
        guard reply != nil else {
            resendPending = true
            // Back before this attempt gave up: no later return comes for it, so it goes again now.
            if returnedMeanwhile { acpmuxReturned() }
            return nil
        }
        // Answered: the current person's request reached acpmux, which keeps what is left to do.
        resendPending = false
        return reply
    }

    private func leaveIfAuto(userId: String?) async {
        // A leave acpmux took and did not finish (`kept: busy`) it finishes at its next start.
        // Only the account signing out's own join is left: acpmux keeps one of another account's.
        var params: [String: Any] = [:]
        if let userId {
            params["userId"] = userId
            // Recorded first, with no daemon: a leave acpmux never gets (it is down, or the app quits
            // first) it still finishes as this account's.
            if !(await recordLeave(userId)) { Self.log.info("sign-out leave: the account was not recorded first") }
        }
        let reply = await send("_acpmux/machine_leave_if_auto", params)
        let kept = (reply?["kept"] as? String) ?? (reply == nil ? "no answer" : "")
        Self.log.info("sign-out leave: left=\((reply?["left"] as? Bool) ?? false, privacy: .public) kept=\(kept, privacy: .public)")
    }

    private func enroll(userId: String) async {
        var backoff = Backoff(initial: .seconds(30), maximum: .seconds(30))
        for attempt in 0..<2 {
            if attempt > 0 {
                // concurrency-allow: Backoff.wait is an async sleep after a failure, once; it blocks no thread.
                do { try await backoff.wait(owner: "cloud.signin-enroll") } catch { return }
                // Signed out or switched meanwhile: that change's work does what is right now.
                guard current == userId else { return }
            }
            guard let access = await accessToken(), !access.isEmpty else { return }
            var params: [String: Any] = extraParams
            params["accessToken"] = access
            params["userId"] = userId
            let outcome = await send("_acpmux/machine_enroll", params)?["outcome"] as? String
            Self.log.info("sign-in enroll: \(outcome ?? "no answer", privacy: .public)")
            // No acpmux yet, or the hub did not answer: once more. Anything else is final.
            if outcome != nil, outcome != "unavailable" { return }
        }
    }
}
