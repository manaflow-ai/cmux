public import CmuxNextSettings
public import Darwin
public import Foundation

/// cmux NIGHTLY's answer to `auth.session.request` on its control socket: a local cmux build of the same
/// user asks for a session, the person says yes or no in NIGHTLY, and on yes NIGHTLY mints a NEW session for
/// the same account through the web route (`POST /api/auth/session-handoff`, 7 days) and answers with it.
/// NIGHTLY's own session never leaves it: no build's socket hands that out.
///
/// Rust decides (cmux-cloud-config `handoff`, ``SessionConsentRules``): the peer's uid, its signature (any
/// valid one, ad hoc included: ``SessionConsentSignerReading``), a cmux main app whose identifier is the bundle
/// id it asks for, NIGHTLY's own Stack project (else `backend_mismatch` naming both), NIGHTLY signed in (else
/// `not_found`), one dialog at a time (else `busy`). This type keeps the socket answer, the dialog's deadline
/// and the HTTP call. It is answered ahead of the socket's access mode, and the connection
/// closes after its one answer. No refusal, error or log carries a token.
public struct SessionConsentResponder: Sendable {
    /// The control socket method.
    public static let method = "auth.session.request"

    /// NIGHTLY's side of a request.
    public struct Nightly: Sendable, Equatable {
        public var stackProjectID: String
        public var apiOrigin: String
        /// Where the web route lives (cmux.com).
        public var authWebOrigin: String
        public var signedIn: Bool
        public var accountEmail: String?

        public init(stackProjectID: String, apiOrigin: String, authWebOrigin: String, signedIn: Bool, accountEmail: String?) {
            self.stackProjectID = stackProjectID
            self.apiOrigin = apiOrigin
            self.authWebOrigin = authWebOrigin
            self.signedIn = signedIn
            self.accountEmail = accountEmail
        }
    }

    /// Reads NIGHTLY's side now.
    public typealias NightlyState = @Sendable () async -> Nightly
    /// Shows the dialog and answers whether the person chose Sign In. Ends (false) when its task is cancelled,
    /// which is how the deadline closes it.
    public typealias Consent = @Sendable (SessionConsentAsk) async -> Bool
    /// Calls the web route with NIGHTLY's own tokens in the native headers; `(0, empty)` when it could not.
    public typealias Mint = @Sendable (SessionConsentMintCall) async -> (status: Int, body: Data)

    let uid: uid_t
    let signers: any SessionConsentSignerReading
    let nightly: NightlyState
    let consent: Consent
    let mint: Mint
    /// Overrides Rust's dialog deadline (tests).
    let consentTimeout: Duration?
    let gate = SessionConsentGate()
    let rules = SessionConsentRules()

    /// - Parameters:
    ///   - uid: The user a client must run as (this process's by default).
    ///   - signers: Reads the client's signature from its audit token.
    ///   - nightly: NIGHTLY's account and backend.
    ///   - consent: The person's answer.
    ///   - mint: The web route call.
    ///   - consentTimeout: Replaces Rust's 120 s deadline (tests only).
    public init(uid: uid_t = getuid(), signers: any SessionConsentSignerReading = SessionConsentCodeCheck(),
                nightly: @escaping NightlyState, consent: @escaping Consent, mint: @escaping Mint,
                consentTimeout: Duration? = nil) {
        self.uid = uid
        self.signers = signers
        self.nightly = nightly
        self.consent = consent
        self.mint = mint
        self.consentTimeout = consentTimeout
    }

    /// The request in `line`, or nil when the line is any other request.
    func request(in line: String) -> ControlRequest? {
        guard line.hasPrefix("{"), case .success(let request) = ControlRouter.decode(line),
              request.method == Self.method else { return nil }
        return request
    }

    /// The response line for `request` from `peer`.
    func respond(to request: ControlRequest, peer: SessionConsentPeer?) async -> String {
        let uidMatches = peer?.uid == uid
        // The Security call only for a process of this user: another user's code is refused unread.
        let signer = uidMatches ? peer.flatMap { signers.signer(of: $0.auditToken) } : nil
        let acquired = await gate.acquire()
        let state = await nightly()
        let facts = SessionConsentRules.Facts(
            peerUidMatches: uidMatches,
            signer: signer.map { .init(identifier: $0.identifier, teamId: $0.teamID, path: $0.path) },
            params: request.params,
            nightly: .init(stackProjectId: state.stackProjectID, apiOrigin: state.apiOrigin, signedIn: state.signedIn,
                           accountEmail: state.accountEmail),
            consentPending: !acquired)
        let decision = rules.decision(facts)
        guard case .ask(let ask) = decision, acquired else {
            if acquired { await gate.release() }
            if case .refuse(let error) = decision { return ControlRouter.encode(id: request.id, error: error) }
            return ControlRouter.encode(id: request.id, error: ControlError(code: "busy", message: "another sign-in request is waiting"))
        }
        let allowed = await answer(ask)
        await gate.release()
        guard allowed else { return ControlRouter.encode(id: request.id, error: ask.declined) }
        guard let call = rules.mintCall(authWebOrigin: state.authWebOrigin, ask: ask) else {
            return ControlRouter.encode(id: request.id, error: SessionConsentRules.unavailable)
        }
        let (status, body) = await mint(call)
        return ControlRouter.encode(id: request.id, result: rules.mintResult(status: status, body: body))
    }

    /// The person's answer, or false once the deadline passes (the dialog's task is cancelled, which closes it).
    func answer(_ ask: SessionConsentAsk) async -> Bool {
        let consent = consent
        let deadline = ContinuousClock.now + (consentTimeout ?? ask.timeout)
        return (try? await ControlDeadline.shared.run(method: Self.method, deadline: deadline) { await consent(ask) }) ?? false
    }
}

/// One consent dialog at a time: a second request while one is open is refused `busy`.
actor SessionConsentGate {
    private var open = false

    /// Takes the one slot; false when a dialog is open.
    func acquire() -> Bool {
        guard !open else { return false }
        open = true
        return true
    }

    func release() { open = false }
}
