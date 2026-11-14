public import CmuxNextCloud
import CmuxNextCompat
import Foundation

/// Signing in enrolls this Mac on the hub (Leo: "Signing in enrolls the machine."). acpmux decides
/// and does all of it (`server/sign_in_follow.rs`: when to enroll, its retry, recording the account
/// signing out before anything waits, and the leave of only a join signing in made). This only
/// tells the app's acpmux who is signed in now (`userId`, or none) and who was before (`previous`).
/// The access token goes only in that request on the local acpmux socket, never in argv, the
/// environment or a log. Signing in publishes the person before its token can be read (its team
/// refresh): the person is reported once that sign-in has finished (``signedInPerson``), and acpmux
/// keeps an enroll with no token pending until a report brings one.
@MainActor
public final class CloudSignInEnroll {
    /// One change to the app's acpmux; true when it took it.
    typealias Send = @MainActor (_ params: [String: Any]) async -> Bool
    /// Records with the acpmux CLI, which needs no daemon, that `userId` signed out at `signedOutAt`
    /// (Unix ms): acpmux drops an intent from before that account's next sign-in.
    typealias RecordLeave = @MainActor (_ userId: String, _ signedOutAt: Int64) async -> Bool

    public static let capability = "machine-signed-in-v1"
    static let method = "_acpmux/machine_signed_in"

    /// Who is signed in now; `.none` while the session is still being read.
    private let person: @MainActor @Sendable () -> String??
    private let accessToken: @MainActor () async -> String?
    private let send: Send
    private let recordLeave: RecordLeave
    private let extra: [String: String]
    /// The change sent last.
    private var last: (userId: String?, previous: String?)?
    private var work: Task<Void, Never>?
    private var following: Task<Void, Never>?

    init(person: @escaping @MainActor @Sendable () -> String??, accessToken: @escaping @MainActor () async -> String?,
         hub: String?, buildTag: String?, recordLeave: @escaping RecordLeave, send: @escaping Send) {
        self.person = person
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
    private var taken: Set<String> = []
    public func acpmuxReturned() {
        guard let last, !taken.contains(last.userId ?? "") else { return }
        submit(last.userId, previous: last.previous)
    }

    /// Waits for every change so far (tests).
    func settled() async { await work?.value }

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

    private func submit(_ userId: String?, previous: String?) {
        let before = work
        // task-owner: one change's request, after the one before; ends with it.
        work = Task { [weak self] in
            await before?.value
            guard let self else { return }
            var params: [String: Any] = extra
            params["userId"] = userId.map { $0 as Any } ?? NSNull()
            params["previous"] = previous.map { $0 as Any } ?? NSNull()
            if userId != nil, let access = await accessToken(), !access.isEmpty { params["accessToken"] = access }
            if await send(params) { taken.insert(userId ?? "") }
        }
    }

    /// Who is signed in, for ``follow()``: `.none` while the session is still being read, at launch
    /// (`restoring`) or in a sign-in that has not finished (`completingSignIn`, whose token cannot be
    /// read until its team refresh ends); `.some(nil)` signed out.
    nonisolated static func signedInPerson(restoring: Bool, completingSignIn: Bool, signedIn: Bool,
                                           userID: String?) -> String?? {
        guard !restoring, !completingSignIn || true else { return .none }
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
    public static func overAcpmux(auth: CloudAuth, buildTag: String?, windows: AcpmuxChatWindows?,
                                  environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> CloudSignInEnroll {
        let hub = auth.configuration.relayAPIBaseURL().absoluteString
        let enroll = CloudSignInEnroll(person: { [weak auth] in
            guard let auth else { return .none }
            // The platform id: a machine record names its person by it, never by the Stack id.
            return signedInPerson(restoring: auth.isRestoring, completingSignIn: auth.coordinator.isLoading,
                                  signedIn: auth.isSignedIn, userID: auth.platformUserID)
        }, accessToken: { [weak auth] in try? await auth?.tokens().access }, hub: hub, buildTag: buildTag,
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
            guard let environment = environment(),
                  let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(30)) else { return false }
            defer { line.close() }
            // Only a line that proved the person may enroll or leave; the daemon refuses any other.
            guard line.isPerson, line.capabilities.contains(capability) else { return false }
            return await line.call(method, params) != nil
        }
        windows?.followAvailability(enroll) { [weak enroll] in enroll?.acpmuxReturned() }
        return enroll
    }
}
