/// Connects the auth coordinator's sign-in callback to the browser session
/// controller without introducing a construction cycle.
@MainActor
final class BrowserAppSessionSignInRelay {
    private var resume: (@MainActor () -> Void)?

    func bind(_ resume: @escaping @MainActor () -> Void) {
        self.resume = resume
    }

    func signedIn() {
        resume?()
    }
}
