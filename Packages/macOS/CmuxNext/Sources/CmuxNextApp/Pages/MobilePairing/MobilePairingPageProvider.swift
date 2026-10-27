import CmuxNextCompat
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextPages
import CmuxNextPhoneAccess
import CmuxNextSettings
import Foundation

/// Serves the Mobile Pairing page's `cmux.mobilePairing.*` ops from the iPhone host
/// (``IPhoneHostService``, the bundled `cmux-mobile-host` that cmux on iPhone connects
/// through), the Cloud account and Settings > Accounts > iPhone:
/// - `status` → the page's `MobilePairingStatus` (state, account, this Mac's name, the
///   switch, hostd's status line, the phones and the pairing requests waiting);
/// - `setAllowed {on}` → writes `mobile.allowIPhoneConnections`, only right after the
///   person's own click or key in the page (the host's record, not the page's);
/// - `answerPair {id, allow}` → Allow or Don't Allow on a waiting request, only from the
///   person's own click or key (as the prompt and Settings > Accounts take it);
/// - stream `changes` → one empty event whenever any of those may have changed.
///
/// No QR code: the one this page used to show was an irx attach ticket for an iPhone app that
/// no longer exists (`MobileIrxHost`, `PairingQRCode` stay). The page shows one again once
/// cmux on iPhone opens a pairing link.
@MainActor
final class MobilePairingPageProvider: PageProvider {
    static let statusOp = "cmux.mobilePairing.status"
    static let setAllowedOp = "cmux.mobilePairing.setAllowed"
    static let answerPairOp = "cmux.mobilePairing.answerPair"
    static let changesStream = "cmux.mobilePairing.changes"
    /// The switch the page reads and writes: the one the iPhone host follows.
    static let switchPath = MobileSettings.allowIPhoneConnectionsPath

    /// What the page reads and writes, so a test can stand in for the app.
    struct Dependencies {
        var host: IPhoneHostService
        var signedIn: @MainActor @Sendable () -> Bool
        /// The signed-in account's email or name, and its id (a change of account is a change).
        var account: @MainActor @Sendable () -> (name: String?, id: String)
        /// `mobile.allowIPhoneConnections`, as Settings has it.
        var allowed: @MainActor @Sendable () -> Bool
        var macName: @Sendable () async -> String
        /// Writes one setting as the person's own change.
        var write: @MainActor @Sendable (_ path: [String], _ value: JSONValue) async throws -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init(services: AppServices) {
        self.init(dependencies: Self.live(services))
    }

    static func live(_ services: AppServices) -> Dependencies {
        Dependencies(
            host: services.iphone,
            signedIn: { [weak services] in services?.cloud.isSignedIn ?? false },
            account: { [weak services] in
                let user = services?.cloud.auth.user
                return (user?.primaryEmail ?? user?.displayName, user?.id ?? "")
            },
            allowed: { [weak services] in services?.settings?.snapshot.mobile.allowIPhoneConnections ?? false },
            macName: { await MacName().displayName() },
            write: { [weak services] path, value in
                guard let settings = services?.settings else {
                    throw PageError(code: "cmux.mobilePairing.unavailable", message: MobilePairingStrings.settingsNotLoaded, retryable: true)
                }
                try await settings.setSetting(at: path, to: value, by: .user)
            })
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return await status()
        case Self.setAllowedOp:
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            guard let on = params["on"]?.boolValue else { throw PageError.invalidParams("on is required") }
            try await dependencies.write(Self.switchPath, .bool(on))
            return .object([:])
        case Self.answerPairOp:
            // Which phone reaches this Mac: the person's own click or key only, never a script.
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id is required") }
            guard case .bool(let allow)? = params["allow"] else { throw PageError.invalidParams("allow is required") }
            guard dependencies.host.answerPairRequest(id: id, allow: allow) else {
                throw PageError.invalidParams("no request from that phone is waiting")
            }
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let dependencies = dependencies
        // task-owner: lives as long as the page's subscription; event-driven (Observation)
        let task = Task { @MainActor in
            var last: String?
            for await fingerprint in ObservationStream({ Self.fingerprint(dependencies) }) {
                guard !Task.isCancelled else { return }
                if fingerprint == last { continue }
                // The first value is the state the page reads with `status`; only changes are events.
                if last != nil { onEvent(.object([:])) }
                last = fingerprint
            }
        }
        return PageSubscription { task.cancel() }
    }

    /// Everything `status` reads that can change while the page is open.
    private static func fingerprint(_ dependencies: Dependencies) -> String {
        let account = dependencies.account()
        return [String(dependencies.signedIn()), account.id, account.name ?? "", String(dependencies.allowed()),
                String(describing: dependencies.host.pageJSON)].joined(separator: "|")
    }

    private func status() async -> JSONValue {
        let host = dependencies.host
        let signedIn = dependencies.signedIn()
        let allowed = dependencies.allowed()
        let state = MobilePairingState.resolve(signedIn: signedIn, allowed: allowed, host: host.phase,
                                               removedReason: IPhoneHostService.removedText)
        let card = host.pageJSON
        let phones = card["phones"]?.arrayValue ?? []
        var reply: [String: JSONValue] = [
            "state": .string(state.wireName),
            "macName": .string(await dependencies.macName()),
            "allowed": .bool(allowed),
            "connectedPhones": JSONValue(phones.filter { $0["connected"]?.boolValue == true }.count),
            // hostd's own words, localized by the host: its status line, how a phone connects,
            // the phones and the requests waiting with their Allow and Don't Allow.
            "host": [
                "status": card["status"] ?? .null,
                "how": card["how"] ?? .null,
                "phonesTitle": card["phones_title"] ?? .null,
                "phones": .array(phones),
                "phonesEmpty": card["phones_empty"] ?? .null,
                // Why the list could not be read: the page says so instead of "no phones".
                "phonesError": card["phones_error"] ?? .null,
                "pendingTitle": card["pending_title"] ?? .null,
                "pending": card["pending"] ?? .array([]),
                "allowTitle": card["pair_allow_title"] ?? .null,
                "denyTitle": card["pair_deny_title"] ?? .null,
                "blocked": card["blocked"] ?? .null,
            ],
        ]
        if signedIn, let account = dependencies.account().name { reply["account"] = .string(account) }
        if case .failed(let reason) = state { reply["failure"] = .string(reason) }
        return .object(reply)
    }
}
