import CmuxNextCompat
import CmuxNextDaemonService
public import CmuxNextMobile
public import CmuxNextPages
import CmuxNextPhoneAccess
public import CmuxNextSettings
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
/// The QR code is this Mac's pairing link (``MobileHostPairInvite``,
/// `cmux-next://pair?mac=&team=&name=&t=&k=`), shown once the host is online for the signed-in
/// account with iPhone connections on. cmux on iPhone opens it from the camera or its own
/// scanner and presents `t`, a single-use pre-approval, in place of the Allow prompt (still only
/// for a phone signed in to this account). The page asks again a minute before the code expires,
/// so a shown code always has that long left.
@MainActor
public final class MobilePairingPageProvider: PageProvider {
    public static let statusOp = "cmux.mobilePairing.status"
    public static let setAllowedOp = "cmux.mobilePairing.setAllowed"
    public static let answerPairOp = "cmux.mobilePairing.answerPair"
    public static let changesStream = "cmux.mobilePairing.changes"
    /// The switch the page reads and writes: the one the iPhone host follows.
    public static let switchPath = MobileSettings.allowIPhoneConnectionsPath

    /// What the page reads and writes, so a test can stand in for the app.
    public struct Dependencies {
        public var host: IPhoneHostService
        public var signedIn: @MainActor @Sendable () -> Bool
        /// The signed-in account's email or name, and its id (a change of account is a change).
        public var account: @MainActor @Sendable () -> (name: String?, id: String)
        /// `mobile.allowIPhoneConnections`, as Settings has it.
        public var allowed: @MainActor @Sendable () -> Bool
        public var macName: @Sendable () async -> String
        /// Writes one setting as the person's own change.
        public var write: @MainActor @Sendable (_ path: [String], _ value: JSONValue) async throws -> Void
        /// This Mac's pairing link (``IPhoneHostService/pairInvite(macName:now:)``), nil until the
        /// host is online for the account with iPhone connections on.
        public var invite: @MainActor @Sendable (_ macName: String) -> MobileHostPairInvite?

        public init(host: IPhoneHostService, signedIn: @escaping @MainActor @Sendable () -> Bool,
                    account: @escaping @MainActor @Sendable () -> (name: String?, id: String),
                    allowed: @escaping @MainActor @Sendable () -> Bool, macName: @escaping @Sendable () async -> String,
                    write: @escaping @MainActor @Sendable (_ path: [String], _ value: JSONValue) async throws -> Void,
                    invite: @escaping @MainActor @Sendable (_ macName: String) -> MobileHostPairInvite? = { _ in nil }) {
            self.host = host
            self.signedIn = signedIn
            self.account = account
            self.allowed = allowed
            self.macName = macName
            self.write = write
            self.invite = invite
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
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

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
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
        let macName = await dependencies.macName()
        var reply: [String: JSONValue] = [
            "state": .string(state.wireName),
            "macName": .string(macName),
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
        if state == .ready, let invite = dependencies.invite(macName), let qr = Self.qr(invite) { reply["qr"] = qr }
        return .object(reply)
    }

    /// The page's `qr`: the link, its code as a PNG data URL, and when to ask for a new one (a
    /// minute before the token expires, when the host mints the next).
    public static func qr(_ invite: MobileHostPairInvite, code: PairingQRCode = PairingQRCode()) -> JSONValue? {
        let url = invite.url
        guard !url.isEmpty, let image = code.pngDataURL(for: url) else { return nil }
        let refreshAt = invite.expiresAt.addingTimeInterval(-60)
        return ["url": .string(url), "image": .string(image),
                "expiresAt": JSONValue(Int((refreshAt.timeIntervalSince1970 * 1000).rounded()))]
    }
}
