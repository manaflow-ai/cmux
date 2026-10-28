import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves the Cloud page's `cmux.cloud.` namespace (webviews/src/pages/cloud) from the Cloud app
/// server: `cmux.cloud.<op>` is the server op `cloud.<op>` on `apps-run` (``CloudAppLinks/ops(local:)``).
///
/// - A page call runs with origin `script`; a call a person approved on the native sheet
///   (``PageCallContext/isConfirmedUser``) runs as `user`, so the server's user-only ops
///   (create, resize, delete, snapshots) run only after that sheet.
/// - `idempotency_key` moves from the params to the op's key. Reads send none (the server refuses
///   a key on a read).
/// - `cmux.cloud.machine.watch` is the page's change stream. The host gets no server event lines
///   yet, so the provider answers the stream from the ops it runs: a machine mutation's answer
///   (`{machine, revision}`) is an `upsert`, a delete is a `removed` at the revision the server
///   names after it. No timer, no polling.
/// - Sign-in and sign-out (confirmed ops) run the app's own account flow (`signIn`, `signOut`).
@MainActor
final class CloudPageProvider: PageProvider {
    /// The namespace prefix the page calls.
    static let prefix = "cmux.cloud."
    static let watchStream = "cmux.cloud.machine.watch"

    private let op: CloudAppOp
    private let signIn: @MainActor () async -> Bool
    private let signOut: @MainActor () async -> Void
    private var watchers: [UUID: @MainActor (CmuxNextSettings.JSONValue) -> Void] = [:]

    /// - Parameters:
    ///   - op: Runs one Cloud app server op (the app passes ``CloudAppLinks/ops(local:)``; tests a fake).
    ///   - signIn: The app's Cloud sign-in; true when the person signed in.
    ///   - signOut: The app's Cloud sign-out.
    ///   Both default to named functions, not async closure literals (cx-bsue).
    init(op: @escaping CloudAppOp, signIn: @escaping @MainActor () async -> Bool = CloudPageProvider.noSignIn,
         signOut: @escaping @MainActor () async -> Void = CloudPageProvider.noSignOut) {
        self.op = op
        self.signIn = signIn
        self.signOut = signOut
    }

    /// The default sign-in: nobody signs in.
    static func noSignIn() async -> Bool { false }
    /// The default sign-out: nothing to end.
    static func noSignOut() async {}

    /// Live watch streams (one per Cloud page that loaded its list).
    var watcherCount: Int { watchers.count }

    func call(_ name: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard name.hasPrefix(Self.prefix) else { throw PageError.unknownOp(name) }
        switch name {
        case "cmux.cloud.auth.sign_in":
            guard context.isConfirmedUser else { throw PageError(code: PageNativeOp.userOnlyCode, message: name) }
            return ["signed_in": .bool(await signIn())]
        case "cmux.cloud.auth.sign_out":
            guard context.isConfirmedUser else { throw PageError(code: PageNativeOp.userOnlyCode, message: name) }
            await signOut()
            return ["signed_in": .bool(false)]
        default:
            break
        }
        let server = String(name.dropFirst("cmux.".count))
        var members = params.objectValue ?? [:]
        let key = members.removeValue(forKey: "idempotency_key")?.stringValue
        let answer = try await run(server, args: .object(members), key: key, context: context)
        await announce(server, args: members, answer: answer, context: context)
        return answer
    }

    func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.watchStream else { throw PageError.unknownOp(stream) }
        // The read names where the projection stands; a server that cannot answer fails the stream.
        _ = try await run("cloud.machine.watch", args: .object([:]), key: nil, context: context)
        let id = UUID()
        watchers[id] = onEvent
        return PageSubscription { [weak self] in self?.watchers[id] = nil }
    }

    private func run(_ server: String, args: CmuxNextSettings.JSONValue, key: String?,
                     context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        let origin: AppsRunRequest.Origin = context.isConfirmedUser ? .user : .script
        do {
            return pageJSON(try await op(server, daemonJSON(args), key, origin))
        } catch let failure as CloudAppOpFailure {
            // No daemon link or no app provider: the page's "disconnected" state, with Retry.
            if Self.linkDownCodes.contains(failure.code) {
                throw PageError(code: "cmux.protocol.transport", message: failure.message, retryable: true)
            }
            let code = failure.code.isEmpty ? "cmux.cloud.failed" : (failure.code.hasPrefix("cmux.") ? failure.code : "cmux." + failure.code)
            throw PageError(code: code, message: failure.message, details: failure.details.map(pageJSON))
        }
    }

    /// Codes that mean the link to the Cloud app server is down, not that the server refused.
    static let linkDownCodes: Set<String> = ["cmux.cloud.relay_unavailable", "provider.unavailable", "unavailable"]

    /// The watch events of one op's answer.
    private func announce(_ server: String, args: [String: CmuxNextSettings.JSONValue], answer: CmuxNextSettings.JSONValue,
                          context: PageCallContext) async {
        guard !watchers.isEmpty else { return }
        if server == "cloud.machine.delete", answer["deleted"]?.boolValue == true, let id = args["machine"]?.stringValue {
            guard let revision = try? await run("cloud.machine.watch", args: .object([:]), key: nil, context: context)["revision"]
            else { return }
            emit(["type": .string("removed"), "revision": revision, "id": .string(id)])
        } else if case .object = answer["machine"], let revision = answer["revision"] {
            emit(["type": .string("upsert"), "revision": revision, "machine": answer["machine"] ?? .null])
        }
    }

    private func emit(_ event: CmuxNextSettings.JSONValue) {
        for watcher in watchers.values { watcher(event) }
    }
}

/// The daemon's JSON as the page's (the two modules each define the same shape); also
/// `cmux cloud open-browser`'s route for ``BrowserTabOpen``.
func pageJSON(_ value: CmuxNextDaemon.JSONValue) -> CmuxNextSettings.JSONValue {
    switch value {
    case .null: .null
    case .bool(let flag): .bool(flag)
    case .number(let number): .number(number)
    case .string(let text): .string(text)
    case .array(let items): .array(items.map(pageJSON))
    case .object(let members): .object(members.mapValues(pageJSON))
    }
}

/// The page's JSON as the daemon's.
private func daemonJSON(_ value: CmuxNextSettings.JSONValue) -> CmuxNextDaemon.JSONValue {
    switch value {
    case .null: .null
    case .bool(let flag): .bool(flag)
    case .number(let number): .number(number)
    case .string(let text): .string(text)
    case .array(let items): .array(items.map(daemonJSON))
    case .object(let members): .object(members.mapValues(daemonJSON))
    }
}
