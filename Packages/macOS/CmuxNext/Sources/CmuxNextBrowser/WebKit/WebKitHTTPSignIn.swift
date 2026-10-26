import CmuxNextCompat
import Foundation

/// One HTTP sign-in challenge of a WebKit tab: a login the user chose to
/// remember answers the first try (Keychain read on the app's system lane);
/// else the tab's sign-in sheet asks, and a checked Remember saves the answer,
/// an unchecked one forgets the saved login (Keychain write on the system
/// lane). Without lanes (tests) nothing is read or written.
struct WebKitHTTPSignIn {
    let memory: BrowserHTTPSignInMemory?
    let key: BrowserHTTPCredentialKey
    let failures: Int
    let space: URLProtectionSpace
    /// The App's lanes (``BrowserSharedStores/lanes``).
    let lanes: (any MayBlockRunner)?
    /// The tab's prompt queue (`WebKitTab.enqueuePrompt`).
    let ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void

    func run(_ completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let memory = memory, key = key, failures = failures, lanes = lanes
        // task-owner: one Keychain read on the system lane, then the answer; ends with it
        Task {
            // The page waits for this answer: the person's load.
            let remembered: BrowserHTTPRememberedLogin?? = try? await lanes?.runSystem(.userBlocking) { memory?.remembered(key, failures: failures) }
            if let remembered = remembered ?? nil {
                return completionHandler(.useCredential,
                                         URLCredential(user: remembered.user, password: remembered.password, persistence: .forSession))
            }
            askUser(completionHandler)
        }
    }

    private func askUser(_ completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let memory = memory, key = key, failures = failures, lanes = lanes
        let kind = BrowserPromptKind.credentials(host: space.host, realm: space.realm.flatMap { $0.isEmpty ? nil : $0 })
        ask(kind, space.host) { response in
            if let memory, let lanes {
                // task-owner: one Keychain write on the system lane; nothing waits on it
                Task { _ = try? await lanes.runSystem(.bestEffort) { memory.record(response, for: key, failures: failures) } }
            }
            guard let credential = BrowserHTTPAuth.urlCredential(for: response) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, credential)
        }
    }
}
