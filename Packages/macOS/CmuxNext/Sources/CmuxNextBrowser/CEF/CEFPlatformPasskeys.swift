import AppKit
import os

/// iCloud Keychain passkeys for the Chromium Host's pages (task p01-process-067, plans/cmux-next/passkeys.md
/// 3.9; feature `chromiumHostPasskeys`). The host's browser process has neither a visible window nor the
/// browser passkey entitlement, so with fork API 31 (cmux_set_webauthn_platform_handler) Chromium sends each
/// iCloud Keychain request here as WEBAUTHN_PLATFORM_REQUEST {token, request}. cmux checks it against the page
/// it shows (``ChromiumPasskeyPolicy``), runs the ceremony as Chrome's browser process does
/// (device/fido/mac/icloud_keychain_sys.mm) through ``ChromiumPlatformPasskeySystem``, over the pane's window,
/// and answers by token. Like a mojo responder (`mojo::WrapCallbackWithDefaultInvokeIfNotRun`), every request
/// is answered once: with the result, or NULL (NotAllowedError) for a refusal; a cancelled one is dropped, and
/// the host's exit ends every open sheet. A ceremony answers only while it is the one its token names
/// (`Ceremony.id`): one that a cancel or the host's end dropped sends and counts nothing, even when a later
/// request (a restarted host's) reuses its token.
///
/// Creates are refused before any prompt or sheet until the fleet proves that the system's client data bytes
/// equal Chromium's (passkeys.md 3.9.5): the system saves the passkey before cmux can compare them, so a
/// mismatch would leave a passkey the site never registered.
///
/// Secrecy (3.9.3, rule 4): the request and reply JSON hold ceremony secrets. Nothing here logs or traces them;
/// a log line names only the operation, the token and the outcome.
final class CEFPlatformPasskeys {
    /// What the relay did since the start, for `debug.cef` `host_passkeys` (chromium-host-bench.py `--native-ui`).
    struct Stats: Sendable, Equatable {
        /// The host was given the handler (cmux can run iCloud Keychain, and the host's shim took it).
        var handlerSet = false
        var permission = ChromiumPasskeyPermission.notDetermined
        var requests = 0
        /// Requests by operation (``requests`` is their sum): a page load's conditional LIST is no sign-in.
        var creates = 0
        var gets = 0
        var lists = 0
        var cancels = 0
        /// System sheets shown (a create or get that passed every check).
        var sheets = 0
        /// Requests answered with a result (an error result included).
        var answered = 0
        /// Refusals by ``ChromiumPasskeyRefusal`` raw value.
        var refused: [String: Int] = [:]
    }

    /// The page of a browser id as the policy reads it, and the window its sheet anchors to; nil for a browser
    /// that is no CEF page of this runtime.
    typealias Pages = @MainActor (Int32) -> (page: ChromiumPasskeyPage, window: NSWindow?)?
    /// Sends one answer to the host (`cmux_shim_webauthn_platform_reply`).
    typealias Reply = @MainActor (Int64, String?) -> Void

    private struct Ceremony {
        /// Which request this is: a token is unique only within one host's process.
        let id: UInt64
        var task: Task<Void, Never>?
        var run: (any ChromiumPasskeyRun)?

        func cancel() {
            task?.cancel()
            run?.cancel()
        }
    }

    /// A ceremony's host token and its own id.
    private nonisolated struct Key: Sendable {
        let token: Int64
        let id: UInt64
    }

    private(set) var stats = Stats()
    private let system: any ChromiumPlatformPasskeySystem
    /// Reads the Public Suffix List (a ~200 KB file), off the main thread, at the first request.
    private let loadSuffixes: @Sendable () -> PublicSuffixList
    private var suffixes: PublicSuffixList?
    private let fetcher: any ChromiumRelatedOriginFetching
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef.passkeys")
    private var ceremonies: [Int64: Ceremony] = [:]
    private var nextCeremony: UInt64 = 0
    /// Creates run: tests only, until the client data bytes are proved equal (the type's comment).
    private let runsCreates: Bool
    /// Passes the listing permission to the attached host (`cmux_shim_set_webauthn_platform`) once it took the
    /// handler; nil before and after a host.
    private var setPlatform: ((Int32) -> Int32)?

    init(system: any ChromiumPlatformPasskeySystem, publicSuffixes: @escaping @Sendable () -> PublicSuffixList,
         fetcher: any ChromiumRelatedOriginFetching = ChromiumRelatedOriginFetcher(), runsCreates: Bool = false) {
        self.system = system
        loadSuffixes = publicSuffixes
        self.fetcher = fetcher
        self.runsCreates = runsCreates
    }

    /// The app's relay: AuthenticationServices, the bundled Public Suffix List and cmux's own fetch.
    static func system() -> CEFPlatformPasskeys {
        CEFPlatformPasskeys(system: ChromiumSystemPasskeys(), publicSuffixes: { PublicSuffixList.bundled() ?? PublicSuffixList(listText: "") })
    }

    /// A host attached (``CEFHostStart/attached()``, before CefInitialize): hands it the handler with the listing
    /// permission (3.9.2), a preinit op the remote shim applies before CefInitialize and again on a host it
    /// restarts. Without the entitlement it sets nothing, and the host's Chromium offers its other authenticators.
    func hostAttached(setPlatform: @escaping (Int32) -> Int32) {
        guard system.isAvailable, self.setPlatform == nil else { return }
        let permission = system.permission
        guard setPlatform(permission.rawValue) == 1 else {
            return logger.error("chromium host passkeys: the shim refused the iCloud Keychain handler")
        }
        self.setPlatform = setPlatform
        (stats.handlerSet, stats.permission) = (true, permission)
    }

    /// The host ended: its tokens can never be answered, so every sheet closes now (task 091's rule).
    func hostEnded() {
        for ceremony in ceremonies.values { ceremony.cancel() }
        ceremonies.removeAll()
        setPlatform = nil
    }

    /// The app became active (the person may come back from System Settings): a changed listing permission reaches
    /// the host now (3.9.2, step 3), so conditional autofill lists iCloud passkeys before the next request. Chrome
    /// reads the state again at each request (icloud_keychain.mm `GetAuthState`); each request here does too.
    func appBecameActive() {
        guard setPlatform != nil else { return }
        permissionChanged(to: system.permission)
    }

    /// A WEBAUTHN_PLATFORM_REQUEST or _CANCEL of the attached host.
    func handle(_ event: ChromiumPlatformPasskeyEvent, runtime: CEFRuntime) {
        handle(event, pages: { [weak runtime] in Self.page(runtime?.tabsByBrowser[$0]) },
               reply: { [weak runtime] token, json in _ = runtime?.shim?.webauthnPlatformReply(token, json) })
    }

    func handle(_ event: ChromiumPlatformPasskeyEvent, pages: @escaping Pages, reply: @escaping Reply) {
        switch event {
        case .cancel(let token):
            stats.cancels += 1
            ceremonies.removeValue(forKey: token)?.cancel()
        case .request(let browser, let token, let rawOperation, let json):
            stats.requests += 1
            // Chromium reads the state at each request (icloud_keychain.mm `GetAuthState`): a change in System Settings
            // reaches the host with the next request, before it is run.
            permissionChanged(to: system.permission)
            // The fork's tokens are unique in its process: a second request for a running token is the host's bug, and
            // the running ceremony keeps its answer.
            guard ceremonies[token] == nil else { return logger.fault("chromium host passkeys: token \(token) asked twice") }
            guard let operation = ChromiumPlatformPasskeyOperation(rawValue: rawOperation) else {
                return refuseUnstarted(token, .malformed, reply: reply)
            }
            switch operation {
            case .create: stats.creates += 1
            case .get: stats.gets += 1
            case .list: stats.lists += 1
            }
            guard operation != .create || runsCreates else { return refuseUnstarted(token, .createUnproven, reply: reply) }
            nextCeremony += 1
            let key = Key(token: token, id: nextCeremony)
            ceremonies[token] = Ceremony(id: key.id, task: Self.start(self, key: key, browser: browser, operation: operation, json: json,
                                                                      pages: pages, reply: reply))
        }
    }

    /// Parses the request off the main thread (a create's JSON carries the page's whole challenge and user id, sizes
    /// the page chooses), then runs its checks and ceremony on the relay; each await on the relay is its own turn.
    private nonisolated static func start(_ relay: CEFPlatformPasskeys, key: Key, browser: Int32,
                                          operation: ChromiumPlatformPasskeyOperation, json: String, pages: @escaping Pages,
                                          reply: @escaping Reply) -> Task<Void, Never> {
        // task-owner: one per WEBAUTHN request; the relay keeps it in `ceremonies` and cancels it on the request's cancel or the host's end
        Task { [weak relay] in
            let request = ChromiumPlatformPasskeyRequest.parse(json, operation: operation)
            let clientData = request.flatMap { $0.operation == .list ? nil : ChromiumClientData($0.clientDataJSON) }
            await relay?.run(key, browser: browser, request: request, clientData: clientData, pages: pages, reply: reply)
        }
    }

    /// Whether `key`'s ceremony is still the one its token names: no cancel, no host end, no reuse of the token.
    private func isLive(_ key: Key) -> Bool {
        ceremonies[key.token]?.id == key.id
    }

    private func run(_ key: Key, browser: Int32, request: ChromiumPlatformPasskeyRequest?, clientData: ChromiumClientData?,
                     pages: Pages, reply: Reply) async {
        guard isLive(key) else { return }
        guard let request else { return refuse(key, .malformed, reply: reply) }
        let suffixes = await publicSuffixes()
        let policy = ChromiumPasskeyPolicy(publicSuffixes: suffixes)
        guard isLive(key) else { return }
        let checked = await verdict(request, clientData: clientData, page: pages(browser)?.page, policy: policy,
                                    relatedOrigins: ChromiumRelatedOrigins(publicSuffixes: suffixes))
        guard isLive(key) else { return }
        let listed: String?
        switch checked {
        case .failure(let refusal): return refuse(key, refusal, reply: reply)
        case .success(let origin): listed = origin
        }
        if request.requestPermission, system.permission == .notDetermined {
            permissionChanged(to: await system.requestPermission())
            guard isLive(key) else { return }
        }
        guard request.operation != .list else {
            let credentials = system.permission == .authorized ? await system.credentials(forRelyingParty: request.rpID) : []
            return answer(key, ChromiumPasskeyReply.json(listing: credentials, permission: system.permission), reply: reply)
        }
        // The page again, now: the fetch or the permission prompt above may have taken it out of view or to
        // another origin.
        guard let current = pages(browser) else { return refuse(key, .unknownBrowser, reply: reply) }
        if case .failure(let refusal) = Self.recheck(policy.check(request, clientData: clientData, page: current.page), listed: listed) {
            return refuse(key, refusal, reply: reply)
        }
        guard let clientData, let window = current.window else { return refuse(key, .noWindow, reply: reply) }
        let run = system.start(ChromiumPasskeyCeremony(request: request, clientData: clientData), anchor: window)
        ceremonies[key.token]?.run = run
        stats.sheets += 1
        let result = await run.result()
        guard isLive(key) else { return }
        guard let json = ChromiumPasskeyReply.json(for: result, chromiumClientData: request.clientDataJSON, permission: system.permission) else {
            return refuse(key, .clientDataMismatch, reply: reply)
        }
        logger.notice("chromium host passkeys: \(String(describing: request.operation), privacy: .public) token \(key.token) answered")
        answer(key, json, reply: reply)
    }

    /// The policy's verdict on `page`, with a related origin request resolved by cmux's own fetch: the caller's
    /// origin when the rp id's list allowed it, nil when the rp id needed no list.
    private func verdict(_ request: ChromiumPlatformPasskeyRequest, clientData: ChromiumClientData?, page: ChromiumPasskeyPage?,
                         policy: ChromiumPasskeyPolicy, relatedOrigins: ChromiumRelatedOrigins) async -> Result<String?, ChromiumPasskeyRefusal> {
        switch policy.check(request, clientData: clientData, page: page) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(.allowed):
            return .success(nil)
        case .success(.needsRelatedOrigins(let callerOrigin)):
            guard let document = await fetcher.wellKnown(for: request.rpID),
                  await Self.lists(callerOrigin, in: document, relatedOrigins) else { return .failure(.relyingParty) }
            return .success(callerOrigin)
        }
    }

    /// Parses and matches the site's list off the main thread: up to ``ChromiumRelatedOriginFetcher/maxBytes``, a
    /// size the site chooses.
    @concurrent
    private nonisolated static func lists(_ origin: String, in document: Data, _ relatedOrigins: ChromiumRelatedOrigins) async -> Bool {
        relatedOrigins.lists(origin, in: document)
    }

    private func publicSuffixes() async -> PublicSuffixList {
        if let suffixes { return suffixes }
        let loaded = await Self.load(loadSuffixes)
        suffixes = loaded
        return loaded
    }

    @concurrent
    private nonisolated static func load(_ suffixes: @Sendable () -> PublicSuffixList) async -> PublicSuffixList {
        suffixes()
    }

    /// A second verdict, with no second fetch: a related origin passes only when it is the one already listed.
    static func recheck(_ verdict: Result<ChromiumPasskeyPolicy.Verdict, ChromiumPasskeyRefusal>,
                        listed: String?) -> Result<Void, ChromiumPasskeyRefusal> {
        switch verdict {
        case .failure(let refusal): .failure(refusal)
        case .success(.allowed): .success(())
        case .success(.needsRelatedOrigins(let origin)): origin == listed ? .success(()) : .failure(.relyingParty)
        }
    }

    /// The page `tab` shows, as the policy reads it, and the window its sheet anchors to.
    static func page(_ tab: CEFTab?) -> (page: ChromiumPasskeyPage, window: NSWindow?)? {
        guard let tab, !tab.isClosed else { return nil }
        let window = tab.container.window
        let onScreen = window.map { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace } ?? false
        let page = ChromiumPasskeyPage(origin: tab.committedURL.flatMap(ChromiumPasskeyPolicy.origin(of:)),
                                       isVisible: onScreen && tab.contentVisibility.isVisible, isAgentDriven: tab.isAgentDriven)
        return (page, window)
    }

    /// Refuses `key`'s ceremony while it is live; a dropped one sends and counts nothing.
    private func refuse(_ key: Key, _ refusal: ChromiumPasskeyRefusal, reply: Reply) {
        guard let ceremony = end(key) else { return }
        ceremony.run?.cancel()
        refuseUnstarted(key.token, refusal, reply: reply)
    }

    /// Refuses a request in the turn it arrived, before it has a ceremony.
    private func refuseUnstarted(_ token: Int64, _ refusal: ChromiumPasskeyRefusal, reply: Reply) {
        stats.refused[refusal.rawValue, default: 0] += 1
        logger.notice("chromium host passkeys: token \(token) refused \(refusal.rawValue, privacy: .public)")
        reply(token, nil)
    }

    private func answer(_ key: Key, _ json: String?, reply: Reply) {
        guard end(key) != nil else { return }
        stats.answered += 1
        reply(key.token, json)
    }

    /// Removes `key`'s ceremony when it is still the one its token names.
    private func end(_ key: Key) -> Ceremony? {
        guard isLive(key) else { return nil }
        return ceremonies.removeValue(forKey: key.token)
    }

    /// The listing permission changed (the person answered the prompt, or System Settings changed it): the
    /// host's Chromium lists iCloud passkeys from now on, or stops (3.9.2, step 3).
    private func permissionChanged(to permission: ChromiumPasskeyPermission) {
        guard let setPlatform, permission != stats.permission else { return }
        stats.permission = permission
        _ = setPlatform(permission.rawValue)
    }
}
