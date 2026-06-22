public import Foundation

/// The owner of all per-browser-surface automation state plus the stateless
/// substrate every `browser.*` control command reads it through.
///
/// This type relocates, out of the app target's control owner
/// (`TerminalController`), the entire browser-automation **state** sub-cluster:
///
/// - the per-surface ``BrowserAutomationSurfaceState`` (element refs, pinned
///   frame selector, init scripts/styles, dialog queue, download-event backlog,
///   not-supported network-request log),
/// - the stateless ``BrowserControlService`` script substrate and the
///   ``BrowserCookieRepository`` cookie source of truth,
/// - the captured browser-download-event observer plus the two app-internal
///   notification names it bridges (``browserDownloadEventDidArriveName`` /
///   ``reactGrabDidCopySelectionName``),
/// - and the per-surface state bookkeeping the witnesses and the worker-lane
///   JS-eval methods drive: element-ref allocation/resolution, the pinned
///   frame-selector read, the in-page dialog queue, the not-supported network
///   log, and the captured-download wait.
///
/// The app target's `TerminalController` keeps the WebKit JS-eval core
/// (`v2RunJavaScript` / `v2RunBrowserJavaScript`), because that core threads its
/// main-actor hop through the app-target socket-command focus-policy stack
/// (`v2MainSync` propagates `socketCommandFocusAllowance`), which no package can
/// reach; it now reads and mutates every byte of per-surface automation state
/// through the injected instance of this type instead of owning it.
///
/// ## Isolation
///
/// `@MainActor @Observable`. Every mutator and reader of the per-surface state is
/// a main-actor path: the `@MainActor` `browser.*` witnesses mutate it directly,
/// and the nonisolated socket-worker JS-eval lane reaches it only through a
/// main-actor hop (``runMainSync(_:)``). State lives where its callers live;
/// co-locating it on the main actor turns the worker-lane reads into plain
/// main-hopped calls and avoids an actor that would only manufacture an isolation
/// domain the callers already share. The pure-dictionary state reads do not touch
/// the focus-policy stack the app's eval core propagates, so a plain main hop is
/// behavior-faithful for them.
@MainActor
@Observable
public final class BrowserAutomationController {
    /// The per-surface automation caches. Mutated directly by the `@MainActor`
    /// witnesses, read from the worker lane through ``runMainSync(_:)``.
    public let surfaceState: BrowserAutomationSurfaceState

    /// The stateless browser-control logic (JS builders, value normalization,
    /// eval-envelope unwrapping, diagnostics, failure classification). A
    /// `Sendable` value reused across every call.
    public nonisolated let control: BrowserControlService

    /// The cookie source of truth for the `browser cookies.*` commands
    /// (`WKHTTPCookieStore` reads/writes/deletes plus `HTTPCookie` ↔ wire-dict
    /// mapping). Stateless and `Sendable`; blocks store callbacks on the injected
    /// awaiter (the same one the JS-eval lane uses).
    public nonisolated let cookies: BrowserCookieRepository

    /// The captured browser-download-event observer token.
    ///
    /// `nonisolated`: written once in ``init`` (on the main actor) and read once
    /// in the `nonisolated deinit` to unregister; there is no concurrent access
    /// (deinit runs only after the last reference is gone), so the box need not be
    /// `@MainActor`-isolated.
    private nonisolated(unsafe) var downloadObserver: (any NSObjectProtocol)?

    // (downloadObserver is read in the nonisolated deinit; the assignment is the
    // only write, on the main actor in init.)

    /// The app-internal notification posted when a captured download event
    /// arrives for a browser surface. `userInfo` carries `surfaceId: UUID` and
    /// `event: [String: Any]`.
    public nonisolated static let browserDownloadEventDidArriveName =
        Notification.Name("cmux.browserDownloadEventDidArrive")

    /// The app-internal notification posted when the React-grab affordance copies
    /// a selection.
    public nonisolated static let reactGrabDidCopySelectionName =
        Notification.Name("cmux.reactGrabDidCopySelection")

    /// The default download-wait timeout (legacy: 10s) when the request omits one.
    public nonisolated static let downloadWaitDefaultTimeoutMs = 10_000

    /// The maximum download-wait timeout (legacy: 120s) a request can ask for.
    public nonisolated static let downloadWaitMaxTimeoutMs = 120_000

    /// Creates the controller and registers the download-event observer.
    ///
    /// - Parameters:
    ///   - cookies: The cookie repository (constructed app-side with the shared
    ///     blocking-await primitive so the cookie-store I/O and the JS-eval I/O
    ///     share one await implementation).
    ///   - control: The stateless script substrate (default-constructed; the
    ///     default ``BrowserEvalEnvelope`` carries the wire constants the v2
    ///     browser RPC has always used).
    public init(
        cookies: BrowserCookieRepository,
        control: BrowserControlService = BrowserControlService()
    ) {
        self.control = control
        self.cookies = cookies
        self.surfaceState = BrowserAutomationSurfaceState()
        let surfaceState = self.surfaceState
        self.downloadObserver = NotificationCenter.default.addObserver(
            forName: Self.browserDownloadEventDidArriveName,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            // The `[String: Any]` payload is not statically `Sendable`; capture it
            // through a `nonisolated(unsafe)` box for the deferred main-actor
            // append. Byte-faithful to the legacy app-side observer, which hopped
            // the append onto a fresh `Task { @MainActor in … }` turn rather than
            // appending inline in the notification dispatch.
            nonisolated(unsafe) let payload = event
            Task { @MainActor in
                surfaceState.appendDownloadEvent(payload, surfaceId: surfaceId)
            }
        }
    }

    deinit {
        if let downloadObserver {
            NotificationCenter.default.removeObserver(downloadObserver)
        }
    }

    /// Drops every per-surface automation entry for the given surfaces. Called on
    /// surface teardown.
    public func cleanupSurfaces(_ surfaceIds: [UUID]) {
        for surfaceId in Set(surfaceIds) {
            surfaceState.removeSurface(surfaceId)
        }
    }

    // MARK: - Main-actor hop

    /// Runs `body` on the main actor and returns its result, the plain main hop
    /// the worker-lane state reads use to touch the `@MainActor` per-surface
    /// state. Unlike the app's eval-core `v2MainSync` it does not propagate the
    /// socket-command focus-policy stack, which is inert for these pure-dictionary
    /// reads (they perform no focus mutation), so the behavior is faithful.
    ///
    /// The result crosses the hop through a `nonisolated(unsafe)` box: the
    /// per-surface state vends `String`/`Int`/`Foundation` dictionary values that
    /// are not statically `Sendable`, exactly as the legacy `v2MainSync<T>` (no
    /// `Sendable` constraint) returned them; the box is written on main and read
    /// on the calling thread with the `DispatchQueue.main.sync` happens-before
    /// edge, so the single hand-off is safe.
    nonisolated func runMainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body() }
        }
    }

    // MARK: - Value transforms (forward to the stateless substrate)

    /// The JSON literal for `value` (forwards to ``BrowserControlService``).
    public nonisolated func jsonLiteral(_ value: Any) -> String {
        control.jsonLiteral(value)
    }

    /// The wire-faithful normalization of a raw JS value (forwards to
    /// ``BrowserControlService``).
    public nonisolated func normalizeJSValue(_ value: Any?) -> Any {
        control.normalizeJSValue(value)
    }

    /// The normalized storage type (`local`/`session`) for a params dict
    /// (forwards to ``BrowserControlService``).
    public nonisolated func storageType(params: [String: Any]) -> String {
        control.storageType(params: params)
    }

    // MARK: - Element / frame resolution

    /// Reads the standard selector aliases (`selector`/`sel`/`element_ref`/`ref`)
    /// from a params dict.
    public nonisolated func selector(in params: [String: Any]) -> String? {
        BrowserAutomationController.trimmedString(params["selector"])
            ?? BrowserAutomationController.trimmedString(params["sel"])
            ?? BrowserAutomationController.trimmedString(params["element_ref"])
            ?? BrowserAutomationController.trimmedString(params["ref"])
    }

    private nonisolated static func trimmedString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Allocates a fresh `@e<n>` element reference for `selector` on `surfaceId`.
    public nonisolated func allocateElementRef(surfaceId: UUID, selector: String) -> String {
        runMainSync {
            self.surfaceState.allocateElementRef(surfaceId: surfaceId, selector: selector)
        }
    }

    /// Resolves a raw selector (a CSS selector or an `@e`/`e<n>` element ref)
    /// against `surfaceId`, returning the concrete selector or `nil`.
    public nonisolated func resolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let selector = runMainSync({
                self.surfaceState.elementRefSelector(refKey: refKey, surfaceId: surfaceId)
            }) else { return nil }
            return selector
        }
        return trimmed
    }

    /// The pinned same-origin frame selector for `surfaceId`, or `nil`.
    public nonisolated func currentFrameSelector(surfaceId: UUID) -> String? {
        runMainSync { self.surfaceState.frameSelector(surfaceId: surfaceId) }
    }

    // MARK: - Network / dialog / download state

    /// Records one not-supported network-interception attempt for `surfaceId`.
    public nonisolated func recordUnsupportedNetworkRequest(surfaceId: UUID, request: [String: Any]) {
        // The `[String: Any]` is not statically `Sendable`; capture it through a
        // `nonisolated(unsafe)` box for the main hop (the worker thread blocks in
        // `runMainSync` until the body returns, so the value is never accessed
        // concurrently). Byte-faithful to the legacy worker-lane recorder.
        nonisolated(unsafe) let payload = request
        runMainSync {
            self.surfaceState.recordUnsupportedNetworkRequest(payload, surfaceId: surfaceId)
        }
    }

    /// The recorded not-supported network-request log for `surfaceId`.
    public func unsupportedNetworkRequests(surfaceId: UUID) -> [[String: Any]] {
        surfaceState.unsupportedNetworkRequests(surfaceId: surfaceId)
    }

    /// Enqueues a pending in-page dialog for `surfaceId`.
    public func enqueueDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        surfaceState.enqueueDialog(
            surfaceId: surfaceId,
            type: type,
            message: message,
            defaultText: defaultText,
            responder: responder
        )
    }

    /// The wire-faithful descriptors of `surfaceId`'s pending dialogs, in queue
    /// order, as Foundation dictionaries (the legacy `v2BrowserPendingDialogs`
    /// shape: `index`/`type`/`message`/`default_text`, with a JSON-null default
    /// text when absent).
    public nonisolated func pendingDialogWireDicts(surfaceId: UUID) -> [[String: Any]] {
        let dialogs = runMainSync { self.surfaceState.pendingDialogs(surfaceId: surfaceId) }
        return dialogs.map { dialog in
            [
                "index": dialog.index,
                "type": dialog.type,
                "message": dialog.message,
                "default_text": dialog.defaultText ?? NSNull()
            ]
        }
    }

    /// Removes and returns the oldest queued download event for `surfaceId`.
    public func popDownloadEvent(surfaceId: UUID) -> [String: Any]? {
        surfaceState.popDownloadEvent(surfaceId: surfaceId)
    }

    /// Appends `script` to `surfaceId`'s document-start init-script cache and
    /// returns the new cache count.
    @discardableResult
    public func appendInitScript(_ script: String, surfaceId: UUID) -> Int {
        surfaceState.appendInitScript(script, surfaceId: surfaceId)
    }

    /// Appends `css` to `surfaceId`'s document-start init-style cache and returns
    /// the new cache count.
    @discardableResult
    public func appendInitStyle(_ css: String, surfaceId: UUID) -> Int {
        surfaceState.appendInitStyle(css, surfaceId: surfaceId)
    }

    /// Pins `surfaceId`'s evaluation to `selector`.
    public func setFrameSelector(_ selector: String, surfaceId: UUID) {
        surfaceState.setFrameSelector(selector, surfaceId: surfaceId)
    }

    /// Clears `surfaceId`'s pinned frame selector.
    public func clearFrameSelector(surfaceId: UUID) {
        surfaceState.clearFrameSelector(surfaceId: surfaceId)
    }
}
