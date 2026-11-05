import CmuxNextCloud
import CmuxNextDaemon
import Foundation

extension CloudAppLinks {
    /// Runs Cloud app ops on `local`'s current connection. A refusal is a
    /// ``CloudAppOpFailure``; origin `user` is sent only where the daemon
    /// allows it (the verified app connection), never upgraded here.
    static func ops(local: DaemonService) -> CloudAppOp {
        let timeout = connectTimeout
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudAppOpFailure(code: "cmux.cloud.relay_unavailable", message: DaemonError.notConnected.description)
            }
            let allowed = await connection.userOriginAllowed
            let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: args, idempotencyKey: key,
                                         origin: origin == .user && allowed ? .user : .script)
            do {
                return try await connection.request(request, timeout: timeout).value
            } catch DaemonError.command(_, let message, let code, let details, _) {
                throw CloudAppOpFailure(code: code ?? "", message: message, details: details)
            }
        }
    }
}

extension CloudAppLinks {
    /// The Cloud page's ops on the classic link (``CloudClassicPageOps``) as a ``CloudAppOp``: origin
    /// `user` is the person; a refusal is a ``CloudAppOpFailure`` with its code.
    static func ops(classic: CloudClassicPageOps) -> CloudAppOp {
        { op, args, _, origin in
            let parsed = (try? recode(args, as: CloudClassicPageOps.Args.self)) ?? .init()
            do {
                let answer = try await classic.run(op, args: parsed, byPerson: origin == .user)
                return try recode(answer, as: JSONValue.self)
            } catch let refusal as CloudClassicPageOps.Refusal {
                let details = refusal.details.isEmpty ? nil : JSONValue.object(refusal.details.mapValues { .string($0) })
                throw CloudAppOpFailure(code: refusal.code, message: refusal.message, details: details)
            }
        }
    }

    /// The classic ops' watch events, as the Cloud page provider's feed sends them.
    @MainActor
    static func feed(classic: CloudClassicPageOps) -> CloudPageProvider.Feed {
        { emit in classic.feed { event in if let value = try? recode(event, as: JSONValue.self) { emit(value) } } }
    }

    private nonisolated static func recode<T: Decodable>(_ value: some Encodable, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

extension CloudClassicPageOps.Backend {
    /// The app's own: ``CloudService``'s sign-in and `/api/vm` calls, and the list in `registry`.
    @MainActor
    static func app(cloud: CloudService, registry: MachineRegistry) -> Self {
        Self(
            signedIn: { [weak cloud] in cloud?.isSignedIn ?? false },
            team: { [weak cloud] in cloud?.auth.teamID },
            unavailable: { [weak cloud] in
                guard let cloud else { return CloudStrings.signInFirst }
                return cloud.unavailableReason
            },
            machines: { [weak registry] in registry?.cloud.map(\.machine) ?? [] },
            limits: { [weak registry] in registry?.cloudLimits },
            hasList: { [weak cloud] in cloud?.hasLoadedCurrentMachines ?? false },
            lastError: { [weak cloud] in cloud?.lastError },
            refresh: { [weak cloud] in _ = await cloud?.refresh() },
            resume: { [weak cloud] id in try await cloud?.resumeMachine(id) },
            pause: { [weak cloud] id in try await cloud?.pauseMachine(id) },
            rename: { [weak cloud] id, name in try await cloud?.renameMachine(id, to: name) },
            delete: { [weak cloud] id in try await cloud?.deleteMachine(id) },
            refusal: classicRefusal,
            signInFirst: CloudStrings.signInFirst
        )
    }

    /// A classic `/api/vm` call's error as the page's refusal, keeping the codes the page acts on:
    /// a plan refusal (its "See plans", with the plan that lifts it), a machine already gone (the
    /// outcome the person asked for) and a lapsed sign-in; anything else fails with its text.
    @MainActor static func classicRefusal(_ error: any Error) -> CloudClassicPageOps.Refusal {
        let text = CloudStrings.errorText(error)
        switch error as? CloudAPIError {
        case let .planRequired(_, _, plan)?:
            return .init(code: CloudAppOpFailure.planRequired, message: text, details: ["plan": plan])
        case let .http(status, code, _, _, _)? where status == 404 || code?.hasSuffix("not_found") == true:
            return .init(code: "cmux.cloud.not_found", message: text)
        case .notSignedIn?:
            return .init(code: "cmux.cloud.auth_required", message: text)
        default:
            return .init(code: "cmux.cloud.failed", message: text)
        }
    }
}
