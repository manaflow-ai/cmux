import CmuxFoundation
import Sentry

/// Applies a ``SentryScrubber`` to outgoing Sentry events and breadcrumbs so
/// file paths, emails, and secrets are redacted before they leave the device.
///
/// Wire it into `SentrySDK.start` via `options.beforeSend`,
/// `options.beforeBreadcrumb`, and (when performance tracing is on)
/// `options.beforeSendSpan`. The Sentry SDK calls those closures on the dispatch
/// queue that produced the event; the scrub is pure and synchronous, so no
/// isolation is required.
///
/// The contract is **scrub every free-text field; preserve only an explicit
/// grouping allowlist**, so a new free-text field is covered by default rather
/// than leaking until someone notices it.
///
/// Scrubbed free-text fields: event `message`, `transaction`, `serverName`,
/// `logger`; exception `value`; exception mechanism `desc` / `helpLink` /
/// `data`; every stack frame's `fileName` / `package` / `contextLine` /
/// `preContext` / `postContext` / `vars` (across exception, thread, and event
/// stack traces); thread `name`; debug-image `codeFile`; request `url` /
/// `queryString` / `fragment` / `headers`; `tags`; `extra`; `context`; and
/// breadcrumb `message` / `data`. Request `cookies` and the `user` identity
/// fields are dropped wholesale because their values rarely match a secret
/// pattern.
///
/// Preserved for grouping (the allowlist): exception `type`, mechanism `type`,
/// `fingerprint`, frame `function` / `module` / `lineNumber` and address
/// fields, `level`, `environment`, `releaseName`, `dist`, `modules`. The
/// `event.error` reference is not serialized by the SDK (it is converted into
/// `exceptions` / `mechanism.data` first), so it needs no handling here.
struct SentryEventScrubber {
    /// The pure value scrubber that does the actual redaction.
    private let scrubber: SentryScrubber

    /// Creates an event scrubber.
    ///
    /// - Parameter scrubber: The underlying value scrubber. Defaults to one bound to the current home directory.
    init(scrubber: SentryScrubber = SentryScrubber()) {
        self.scrubber = scrubber
    }

    /// Redacts sensitive content from an event in place and returns it.
    ///
    /// Returns the same event so it can be used directly as `beforeSend`. The
    /// event is never dropped (returning `nil` would discard it); scrubbing only
    /// rewrites field values.
    ///
    /// - Parameter event: The event Sentry is about to send.
    /// - Returns: The scrubbed event.
    func scrub(_ event: Event) -> Event {
        event.message = scrub(event.message)

        event.serverName = scrubber.scrub(optional: event.serverName)
        event.transaction = scrubber.scrub(optional: event.transaction)
        event.logger = scrubber.scrub(optional: event.logger)

        if let exceptions = event.exceptions {
            for exception in exceptions {
                // Redact the human-readable value; keep `type` for grouping.
                exception.value = scrubber.scrub(optional: exception.value)
                scrubFrames(in: exception.stacktrace)
                scrubMechanism(exception.mechanism)
            }
        }

        if let threads = event.threads {
            for thread in threads {
                thread.name = scrubber.scrub(optional: thread.name)
                scrubFrames(in: thread.stacktrace)
            }
        }
        scrubFrames(in: event.stacktrace)

        if let debugMeta = event.debugMeta {
            for image in debugMeta {
                // `codeFile` is the on-disk path to the loaded binary, which for
                // dev/home-launched builds can carry `/Users/<name>/…`.
                image.codeFile = scrubber.scrub(optional: image.codeFile)
            }
        }

        scrubRequest(event.request)
        scrubUser(event.user)

        if let tags = event.tags {
            // Key-aware so a tag like `access_token` is redacted by name even
            // when its value matches no standalone secret pattern.
            event.tags = scrubber.scrub(dictionary: tags).compactMapValues { $0 as? String }
        }
        if let extra = event.extra {
            event.extra = scrubber.scrub(dictionary: extra)
        }
        if let context = event.context {
            // `context` carries the per-key dictionaries set via
            // `scope.setContext(value:key:)`, where cmux puts cwd / path / URL
            // data. Route through the context scrubber so the OUTER context name
            // is also a redaction boundary (a `credentials`/`auth` context is
            // dropped wholesale), matching the key-aware handling tags/extra get.
            event.context = scrubber.scrub(context: context)
        }

        if let breadcrumbs = event.breadcrumbs {
            for breadcrumb in breadcrumbs {
                scrub(breadcrumb)
            }
        }

        return event
    }

    /// Redacts sensitive content from a breadcrumb in place and returns it.
    ///
    /// Suitable as `beforeBreadcrumb`. Returns the same breadcrumb (never `nil`,
    /// which would drop it).
    ///
    /// - Parameter breadcrumb: The breadcrumb Sentry is about to record.
    /// - Returns: The scrubbed breadcrumb.
    @discardableResult
    func scrub(_ breadcrumb: Breadcrumb) -> Breadcrumb {
        breadcrumb.message = scrubber.scrub(optional: breadcrumb.message)
        if let data = breadcrumb.data {
            breadcrumb.data = scrubber.scrub(dictionary: data)
        }
        return breadcrumb
    }

    /// Redacts the description, data, and tags of a performance span in place.
    ///
    /// Suitable as `beforeSendSpan`. When performance tracing is on, auto network
    /// / file-I/O spans serialize URLs (`http.query`, `url`), file paths, and
    /// other content in `spanDescription` and `data`; the transaction event
    /// itself is scrubbed by ``scrub(_:)-(Event)`` via `beforeSend`, but child
    /// spans pass through `beforeSendSpan` instead. Returns the same span (never
    /// `nil`, which would drop it). `operation` and `origin` name the span kind
    /// (e.g. `http.client`) and are preserved.
    ///
    /// - Parameter span: The span Sentry is about to send.
    /// - Returns: The scrubbed span.
    @discardableResult
    func scrub(_ span: any Span) -> any Span {
        span.spanDescription = scrubber.scrub(optional: span.spanDescription)
        // `data` / `tags` are read-only; scrub via the key-aware dictionary
        // scrubber and rewrite each entry through the per-key setters.
        for (key, value) in scrubber.scrub(dictionary: span.data) {
            span.setData(value: value, key: key)
        }
        let scrubbedTags = scrubber.scrub(dictionary: span.tags)
        for (key, value) in scrubbedTags {
            if let stringValue = value as? String {
                span.setTag(value: stringValue, key: key)
            }
        }
        return span
    }

    /// Rebuilds a message with its rendered text, template, and params scrubbed.
    ///
    /// `SentryMessage.formatted` is read-only, so the message must be rebuilt
    /// from a scrubbed `formatted` string. This matters because
    /// `SentrySDK.capture(message:)` populates `formatted` and leaves the
    /// `message` template `nil`, so scrubbing only the template would leak the
    /// captured message text verbatim.
    private func scrub(_ message: SentryMessage?) -> SentryMessage? {
        guard let message else { return nil }
        let rebuilt = SentryMessage(formatted: scrubber.scrub(message.formatted))
        rebuilt.message = scrubber.scrub(optional: message.message)
        rebuilt.params = message.params?.map { scrubber.scrub($0) }
        return rebuilt
    }

    /// Redacts the description, help link, and data payload of an exception mechanism.
    ///
    /// `capture(error:)` copies `NSError.userInfo` (which can hold
    /// `NSFilePathErrorKey`, URLs, and other fields) into `mechanism.data`. The
    /// `type` is left untouched so grouping is unaffected.
    private func scrubMechanism(_ mechanism: Mechanism?) {
        guard let mechanism else { return }
        mechanism.desc = scrubber.scrub(optional: mechanism.desc)
        mechanism.helpLink = scrubber.scrub(optional: mechanism.helpLink)
        if let data = mechanism.data {
            mechanism.data = scrubber.scrub(dictionary: data)
        }
    }

    /// Redacts the free-text fields of every frame in a stack trace.
    ///
    /// Scrubs the path fields (`fileName`, `package`), the captured source lines
    /// (`contextLine`, `preContext`, `postContext`), and local variable values
    /// (`vars`), all of which can carry paths, emails, tokens, or passwords. The
    /// grouping/symbol fields (`function`, `module`, `lineNumber`, the address
    /// fields) are preserved so Sentry issue grouping is unaffected.
    private func scrubFrames(in stacktrace: SentryStacktrace?) {
        guard let frames = stacktrace?.frames else { return }
        for frame in frames {
            frame.fileName = scrubber.scrub(optional: frame.fileName)
            frame.package = scrubber.scrub(optional: frame.package)
            frame.contextLine = scrubber.scrub(optional: frame.contextLine)
            frame.preContext = frame.preContext?.map { scrubber.scrub($0) }
            frame.postContext = frame.postContext?.map { scrubber.scrub($0) }
            if let vars = frame.vars {
                frame.vars = scrubber.scrub(dictionary: vars)
            }
        }
    }

    /// Redacts URL, query, and headers from an HTTP request context and drops cookies.
    ///
    /// `url` and `queryString` are structured: their query parameters are redacted
    /// by key via ``SentryScrubber/scrubQueryString(_:)`` (the maintained denylist
    /// is the single source of truth), so a sensitive param like `_csrf=…` or
    /// `_vercel_jwt=…` is caught even when its value matches no free-text secret
    /// pattern. The non-query base of `url` still goes through the generic
    /// ``SentryScrubber/scrub(_:)`` so userinfo credentials and home paths in it
    /// are redacted.
    private func scrubRequest(_ request: SentryRequest?) {
        guard let request else { return }
        request.url = scrubURL(request.url)
        request.queryString = request.queryString.map { scrubber.scrubQueryString($0) }
        request.fragment = scrubber.scrub(optional: request.fragment)
        // Cookies are dropped wholesale: cookie names vary (session, sid, auth,
        // …), so pattern-scrubbing the value cannot reliably catch every secret.
        request.cookies = nil
        if let headers = request.headers {
            // Route through the key-aware dictionary scrubber so credential
            // headers (Authorization, Cookie, …) are redacted by name.
            request.headers = scrubber.scrub(dictionary: headers).compactMapValues { $0 as? String }
        }
    }

    /// Scrubs a request URL, routing any query component through the structured
    /// query-string scrubber while the base goes through the generic scrubber.
    ///
    /// The base (scheme/userinfo/host/path) keeps the free-text rules so URL
    /// credentials and home paths are redacted; the query part after the first
    /// `?` is redacted by parameter key. Fragments are carried on
    /// `SentryRequest.fragment` separately, so a `#frag` tail is not split here.
    private func scrubURL(_ url: String?) -> String? {
        guard let url else { return nil }
        guard let questionMark = url.firstIndex(of: "?") else {
            return scrubber.scrub(url)
        }
        let base = String(url[url.startIndex..<questionMark])
        let query = String(url[url.index(after: questionMark)...])
        return "\(scrubber.scrub(base))?\(scrubber.scrubQueryString(query))"
    }

    /// Drops identifying fields from the user context.
    private func scrubUser(_ user: User?) {
        guard let user else { return }
        // Both inits set `sendDefaultPii = false`, but any user object attached
        // by app/SDK/scope code still flows through here. A last-mile PII
        // scrubber drops identity fields wholesale rather than pattern-matching
        // them: a username or display name rarely looks like an email/path/secret.
        user.userId = nil
        user.email = nil
        user.username = nil
        user.name = nil
        user.ipAddress = nil
        user.geo = nil
        if let data = user.data {
            user.data = scrubber.scrub(dictionary: data)
        }
    }
}
