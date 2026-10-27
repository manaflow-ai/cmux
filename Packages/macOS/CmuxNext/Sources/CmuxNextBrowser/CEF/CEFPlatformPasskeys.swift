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
/// the host's exit ends every open sheet.
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
        var task: Task<Void, Never>?
        var run: (any ChromiumPasskeyRun)?

        func cancel() {
            task?.cancel()
            run?.cancel()
        }
    }

    private(set) var stats = Stats()
    private let system: any ChromiumPlatformPasskeySystem
    /// Reads the Public Suffix List (a ~200 KB file), off the main thread, at the first request.
    private let loadSuffixes: @Sendable () -> PublicSuffixList
    private var suffixes: PublicSuffixList?
    private let fetcher: any ChromiumRelatedOriginFetching
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef.passkeys")
    private var ceremonies: [Int64: Ceremony] = [:]
    /// Passes the listing permission to the attached host (`cmux_shim_set_webauthn_platform`) once it took the
    /// handler; nil before and after a host.
    private var setPlatform: ((Int32) -> Int32)?
    private var activation: (any NSObjectProtocol)?
    private let center: NotificationCenter

    init(system: any ChromiumPlatformPasskeySystem, publicSuffixes: @escaping @Sendable () -> PublicSuffixList,
         fetcher: any ChromiumRelatedOriginFetching = ChromiumRelatedOriginFetcher(), center: NotificationCenter = .default) {
        self.system = system
        loadSuffixes = publicSuffixes
        self.fetcher = fetcher
        self.center = center
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
        observeActivation()
    }

    /// The host ended: its tokens can never be answered, so every sheet closes now (task 091's rule).
    func hostEnded() {
        for ceremony in ceremonies.values { ceremony.cancel() }
        ceremonies.removeAll()
        setPlatform = nil
        if let activation { center.removeObserver(activation) }
        activation = nil
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
            // The fork's tokens are unique in its process: a second request for a running token is the host's bug, and
            // the running ceremony keeps its answer.
            guard ceremonies[token] == nil else { return logger.fault("chromium host passkeys: token \(token) asked twice") }
            guard let operation = ChromiumPlatformPasskeyOperation(rawValue: rawOperation) else {
                return refuse(token, .malformed, reply: reply)
            }
            ceremonies[token] = Ceremony()
            let task = Task { [weak self] in
                let (request, clientData) = await Self.parse(json, operation: operation)
                await self?.run(token, browser: browser, request: request, clientData: clientData, pages: pages, reply: reply)
            }
            ceremonies[token]?.task = task
        }
    }

    /// The request and its client data, parsed off the main thread (a create's JSON carries the page's whole
    /// challenge and user id, sizes the page chooses).
    @concurrent
    private nonisolated static func parse(_ json: String, operation: ChromiumPlatformPasskeyOperation)
        async -> (ChromiumPlatformPasskeyRequest?, ChromiumClientData?) {
        let request = ChromiumPlatformPasskeyRequest.parse(json, operation: operation)
        return (request, request.flatMap { $0.operation == .list ? nil : ChromiumClientData($0.clientDataJSON) })
    }

    private func run(_ token: Int64, browser: Int32, request: ChromiumPlatformPasskeyRequest?, clientData: ChromiumClientData?,
                     pages: Pages, reply: Reply) async {
        guard ceremonies[token] != nil else { return }
        guard let request else { return refuse(token, .malformed, reply: reply) }
        let suffixes = await publicSuffixes()
        let policy = ChromiumPasskeyPolicy(publicSuffixes: suffixes)
        guard ceremonies[token] != nil else { return }
        let listed: String?
        switch await verdict(request, clientData: clientData, page: pages(browser)?.page, policy: policy,
                             relatedOrigins: ChromiumRelatedOrigins(publicSuffixes: suffixes)) {
        case .failure(let refusal): return refuse(token, refusal, reply: reply)
        case .success(let origin): listed = origin
        }
        guard ceremonies[token] != nil else { return }
        if request.requestPermission, system.permission == .notDetermined {
            permissionChanged(to: await system.requestPermission())
            guard ceremonies[token] != nil else { return }
        }
        guard request.operation != .list else {
            let credentials = system.permission == .authorized ? await system.credentials(forRelyingParty: request.rpID) : []
            return answer(token, ChromiumPasskeyReply.json(listing: credentials, permission: system.permission), reply: reply)
        }
        // The page again, now: the fetch or the permission prompt above may have taken it out of view or to
        // another origin.
        guard let current = pages(browser) else { return refuse(token, .unknownBrowser, reply: reply) }
        if case .failure(let refusal) = Self.recheck(policy.check(request, clientData: clientData, page: current.page), listed: listed) {
            return refuse(token, refusal, reply: reply)
        }
        guard let clientData, let window = current.window else { return refuse(token, .noWindow, reply: reply) }
        let run = system.start(ChromiumPasskeyCeremony(request: request, clientData: clientData), anchor: window)
        ceremonies[token]?.run = run
        stats.sheets += 1
        let result = await run.result()
        guard ceremonies[token] != nil else { return }
        guard let json = ChromiumPasskeyReply.json(for: result, chromiumClientData: request.clientDataJSON, permission: system.permission) else {
            return refuse(token, .clientDataMismatch, reply: reply)
        }
        logger.notice("chromium host passkeys: \(String(describing: request.operation), privacy: .public) token \(token) answered")
        answer(token, json, reply: reply)
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
                  relatedOrigins.lists(callerOrigin, in: document) else { return .failure(.relyingParty) }
            return .success(callerOrigin)
        }
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

    private func refuse(_ token: Int64, _ refusal: ChromiumPasskeyRefusal, reply: Reply) {
        ceremonies.removeValue(forKey: token)?.run?.cancel()
        stats.refused[refusal.rawValue, default: 0] += 1
        logger.notice("chromium host passkeys: token \(token) refused \(refusal.rawValue, privacy: .public)")
        reply(token, nil)
    }

    private func answer(_ token: Int64, _ json: String?, reply: Reply) {
        guard ceremonies.removeValue(forKey: token) != nil else { return }
        stats.answered += 1
        reply(token, json)
    }

    /// The listing permission changed (the person answered the prompt, or System Settings changed it): the
    /// host's Chromium lists iCloud passkeys from now on, or stops (3.9.2, step 3).
    private func permissionChanged(to permission: ChromiumPasskeyPermission) {
        guard let setPlatform, permission != stats.permission else { return }
        stats.permission = permission
        _ = setPlatform(permission.rawValue)
    }

    /// A change in System Settings shows on the next app activation, as Chrome reads the state again then.
    private func observeActivation() {
        guard activation == nil else { return }
        activation = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self else { return }
                permissionChanged(to: system.permission)
            }
        }
    }
}
