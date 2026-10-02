import AppKit
import CmuxNextCloud
import CmuxNextFeed
import Foundation

/// The app's feed (plans/cmux-next/feed.md): one `FeedModel` mirroring the
/// user's `FeedDO` through `CloudFeedSource`. It starts once the cmux account
/// is signed in (the Stack session token is the bearer until install tokens
/// exist) and reports the app's active state as presence for the owner's
/// push rule. View state (panel, selection, drafts) stays in this client.
@MainActor
final class FeedService {
    let model: FeedModel
    private let source: CloudFeedSource
    private let auth: CloudAuth
    private var started = false
    private var observers: [any NSObjectProtocol] = []

    /// The API Worker for this build: `CMUX_NEXT_FEED_API_URL`, else staging
    /// for development auth and production for production auth.
    static func apiBaseURL(auth: CloudAuth, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["CMUX_NEXT_FEED_API_URL"], let url = URL(string: raw) { return url }
        return URL(string: auth.configuration.isProductionAuth ? "https://cloud-api.cmux.dev" : "https://cloud-api-staging.cmux.dev")!
    }

    init(auth: CloudAuth) {
        self.auth = auth
        // The answer's device label is the owner's record (the install); this name is only the overlay's.
        source = CloudFeedSource(apiBaseURL: Self.apiBaseURL(auth: auth), device: "Mac") { [auth] in
            try await auth.tokens().access
        }
        model = FeedModel(source: source)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.source.setPresence(active: true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.source.setPresence(active: false) }
            },
        ]
        // task-owner: FeedService, one-shot: starts the mirror after the stored session restores.
        Task { [weak self] in
            await auth.awaitRestored()
            self?.startIfSignedIn()
        }
    }

    /// Starts the mirror when signed in; the panel calls it again on open (after a sign-in).
    func startIfSignedIn() {
        guard !started, auth.isSignedIn else { return }
        started = true
        source.setPresence(active: NSApp.isActive)
        model.start()
    }

    var isSignedIn: Bool { auth.isSignedIn }

    func stop() {
        model.stop()
        started = false
    }
}
