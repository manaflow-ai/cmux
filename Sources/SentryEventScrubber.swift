import CmuxFoundation
import Sentry

/// Applies a ``SentryScrubber`` to outgoing Sentry events and breadcrumbs so
/// file paths, emails, and secrets are redacted before they leave the device.
///
/// Wire it into `SentrySDK.start` via `options.beforeSend` and
/// `options.beforeBreadcrumb`. The Sentry SDK calls those closures on the
/// dispatch queue that produced the event; the scrub is pure and synchronous,
/// so no isolation is required.
///
/// The scrubber walks every field that can carry user content — event message,
/// exception values, thread/exception/event stack-frame paths, request URL /
/// query / headers, transaction name, server name, `tags`, `extra`, `context`,
/// and breadcrumb `message` / `data` — while leaving grouping-relevant fields
/// (exception `type`, fingerprint, frame `function` / `module` / `lineNumber`)
/// untouched so Sentry issue grouping is unaffected. Request `cookies` and the
/// `user` identity fields are dropped wholesale rather than pattern-scrubbed,
/// because cookie/identity values rarely match a secret pattern.
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

        if let exceptions = event.exceptions {
            for exception in exceptions {
                // Redact the human-readable value; keep `type` for grouping.
                exception.value = scrubber.scrub(optional: exception.value)
                scrubFrames(in: exception.stacktrace)
            }
        }

        if let threads = event.threads {
            for thread in threads {
                scrubFrames(in: thread.stacktrace)
            }
        }
        scrubFrames(in: event.stacktrace)

        scrubRequest(event.request)
        scrubUser(event.user)

        if let tags = event.tags {
            event.tags = tags.mapValues { scrubber.scrub($0) }
        }
        if let extra = event.extra {
            event.extra = scrubber.scrub(dictionary: extra)
        }
        if let context = event.context {
            // `context` carries the per-key dictionaries set via
            // `scope.setContext(value:key:)`, where cmux puts cwd / path / URL
            // data; scrub every nested value.
            event.context = context.mapValues { scrubber.scrub(dictionary: $0) }
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

    /// Redacts file paths in every frame of a stack trace, preserving symbol metadata.
    private func scrubFrames(in stacktrace: SentryStacktrace?) {
        guard let frames = stacktrace?.frames else { return }
        for frame in frames {
            frame.fileName = scrubber.scrub(optional: frame.fileName)
            frame.package = scrubber.scrub(optional: frame.package)
            // `function`, `module`, and `lineNumber` are grouping-relevant and
            // are left untouched.
        }
    }

    /// Redacts URL, query, and headers from an HTTP request context and drops cookies.
    private func scrubRequest(_ request: SentryRequest?) {
        guard let request else { return }
        request.url = scrubber.scrub(optional: request.url)
        request.queryString = scrubber.scrub(optional: request.queryString)
        request.fragment = scrubber.scrub(optional: request.fragment)
        // Cookies are dropped wholesale: cookie names vary (session, sid, auth,
        // …), so pattern-scrubbing the value cannot reliably catch every secret.
        request.cookies = nil
        if let headers = request.headers {
            request.headers = headers.mapValues { scrubber.scrub($0) }
        }
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
