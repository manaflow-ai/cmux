import AppKit
import CmuxAuthRuntime
import Foundation

/// Opens hosted sign-in in the user's default browser.
@MainActor
final class DefaultBrowserAuthSessionFactory: HostBrowserAuthSessionFactory {
    private let opener: @MainActor (URL) -> Bool

    init(opener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.opener = opener
    }

    func makeSession(
        signInURL: URL,
        callbackScheme _: String,
        completion _: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession {
        DefaultBrowserAuthSession(signInURL: signInURL, opener: opener)
    }
}

@MainActor
private final class DefaultBrowserAuthSession: HostBrowserAuthSession {
    private let signInURL: URL
    private let opener: @MainActor (URL) -> Bool

    init(signInURL: URL, opener: @escaping @MainActor (URL) -> Bool) {
        self.signInURL = signInURL
        self.opener = opener
    }

    func start() -> Bool {
        opener(signInURL)
    }

    func cancel() {
        // NSWorkspace opens the user's browser as a separate app; there is no
        // owned AuthenticationServices session for cmux to cancel.
    }
}
