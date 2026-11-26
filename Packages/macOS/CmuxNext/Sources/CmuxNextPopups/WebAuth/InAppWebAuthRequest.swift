package import Foundation

/// A sign-in the app starts itself (its own GitHub connect, cmux#55885's follow-up): GitHub's page opens in the app's
/// sign-in panel over its window, the shim stops GitHub's return before the console page loads, and the app finishes the
/// connect with no page, no other browser and no "reopen in" prompt (Leo, 2026-11-25: "you're already in the app. so it
/// shouldnt say shit"). The rules live with whoever makes it; this only carries them to the broker.
@MainActor
package final class InAppWebAuthRequest: WebAuthSessionRequest {
    package let id = UUID()
    package let url: URL
    package let callback: WebAuthCallback
    package var isEphemeral: Bool { false }
    package var opensOverAppWindow: Bool { true }
    private let match: (URL) -> Bool
    private let next: (URL) -> URL?
    private let onComplete: (URL) -> Void
    private let onCancel: () -> Void

    /// - Parameters:
    ///   - callback: What the shim stops before it loads.
    ///   - matches: Whether a stopped or reached URL ends the panel; `callback` alone when nil.
    ///   - redirect: Where a stopped URL that does not end it goes instead (nil: it loads).
    package init(url: URL, callback: WebAuthCallback, matches: ((URL) -> Bool)? = nil, redirect: @escaping (URL) -> URL? = { _ in nil },
                 complete: @escaping (URL) -> Void, cancel: @escaping () -> Void) {
        self.url = url
        self.callback = callback
        match = matches ?? { callback.matches($0) }
        next = redirect
        onComplete = complete
        onCancel = cancel
    }

    package func matches(_ url: URL) -> Bool { match(url) }
    package func complete(with url: URL) { onComplete(url) }
    package func cancel() { onCancel() }
    package func redirect(_ url: URL) -> URL? { next(url) }
}
