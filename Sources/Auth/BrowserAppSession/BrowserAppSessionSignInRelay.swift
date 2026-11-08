/// Connects the auth coordinator's sign-in callback to the browser session
/// controller without introducing a construction cycle.
@MainActor
final class BrowserAppSessionSignInRelay {
    private var beginTransition: (@MainActor () -> Void)?
    private var resume: (@MainActor () async -> Void)?

    func bind(
        beginTransition: @escaping @MainActor () -> Void,
        resume: @escaping @MainActor () async -> Void
    ) {
        self.beginTransition = beginTransition
        self.resume = resume
    }

    func sessionWillTransition() {
        beginTransition?()
    }

    func signedIn() async {
        await resume?()
    }
}
