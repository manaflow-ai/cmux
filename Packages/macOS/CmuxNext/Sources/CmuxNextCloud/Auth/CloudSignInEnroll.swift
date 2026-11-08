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
/// - Signed out: `_acpmux/machine_leave_if_auto`, which leaves only a join signing in made. A Mac
///   joined with a pair code or a join line stays joined. acpmux marks the leave before it acts and
///   finishes one cut short at its next start, before its relay. A leave acpmux did not answer (it
///   was restarting) is kept, that one only, and sent again when the app's acpmux connection comes
///   back (``acpmuxReturned()``); a sign-in drops it. Signed out at launch asks again, for a sign-out
///   whose request never reached acpmux before the app quit.
/// - Another person: the leave, then the enroll.
///
/// Event-driven (an ``ObservationStream`` of the signed-in person); its only wait is the retry's
/// ``Backoff``.
@MainActor
public final class CloudSignInEnroll {
    /// One request on a fresh line to the app's acpmux, which must serve `machine-enroll-v1`; nil when
    /// no acpmux answered, it lacks the capability, or the request failed.
    public typealias Call = @MainActor (_ method: String, _ params: [String: Any]) async -> [String: Any]?

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
    private let extraParams: [String: String]
    /// The person the last change was for; nil signed out.
    private var current: String?
    /// Whether the session has been read once since launch.
    private var decided = false
    /// A sign-out's leave acpmux did not answer: sent again when acpmux is back, while signed out.
    private(set) var leavePending = false
    /// A leave is waiting on acpmux now; `returnedMeanwhile`: the connection came back while it waited.
    private var leaving = false
    private var returnedMeanwhile = false
    /// The work for the changes so far, one after another.
    private var work: Task<Void, Never>?
    private var following: Task<Void, Never>?

    /// `hub`: the platform origin the app's `cmux machine add` mints on, when set. `buildTag`: a DEV
    /// build's tag, so its machine is named apart.
    public convenience init(auth: CloudAuth, hub: String?, buildTag: String?, call: @escaping Call) {
        self.init(person: { [weak auth] in
            guard let auth, !auth.isRestoring else { return .restoring }
            guard auth.isSignedIn else { return .signedOut }
            // Signed in with no user read yet is no person yet.
            return auth.user.map { .signedIn($0.id) } ?? .restoring
        }, accessToken: { [weak auth] in try? await auth?.tokens().access }, hub: hub, buildTag: buildTag, call: call)
    }

    init(person: @escaping @MainActor @Sendable () -> Person, accessToken: @escaping @MainActor () async -> String?,
         hub: String?, buildTag: String?, call: @escaping Call) {
        self.person = person
        self.accessToken = accessToken
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

    /// The app's acpmux connection is up again (a restarted daemon answers): a sign-out's leave it did not
    /// answer is sent once more, after any change still running, unless a sign-in came since.
    public func acpmuxReturned() {
        if leaving { returnedMeanwhile = true }
        guard leavePending, current == nil else { return }
        leavePending = false
        let before = work
        // task-owner: the one pending leave, after the changes before it; ends with it.
        work = Task { [weak self] in
            await before?.value
            guard let self, current == nil else { return }
            await leaveIfAuto()
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
        decided = true
        // Signed in again: a leave not answered yet is not wanted any more.
        if next != nil { leavePending = false }
        current = next
        let before = work
        // task-owner: one change's leave and enroll, after the previous change's; ends with them.
        work = Task { [weak self] in
            await before?.value
            guard let self else { return }
            if leave { await leaveIfAuto() }
            if let next { await enroll(userId: next) }
        }
    }

    private func leaveIfAuto() async {
        leaving = true
        returnedMeanwhile = false
        let reply = await call("_acpmux/machine_leave_if_auto", [:])
        leaving = false
        // No reply (acpmux restarting): kept, and sent again when acpmux is back (``acpmuxReturned()``),
        // unless signed in by then. A leave acpmux took and did not finish (`kept: busy`) it finishes
        // at its next start.
        if reply == nil, current == nil {
            leavePending = true
            // Back before this attempt gave up: no later return comes for it, so it goes again now.
            if returnedMeanwhile { acpmuxReturned() }
        }
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
            let outcome = await call("_acpmux/machine_enroll", params)?["outcome"] as? String
            Self.log.info("sign-in enroll: \(outcome ?? "no answer", privacy: .public)")
            // No acpmux yet, or the hub did not answer: once more. Anything else is final.
            if outcome != nil, outcome != "unavailable" { return }
        }
    }
}
