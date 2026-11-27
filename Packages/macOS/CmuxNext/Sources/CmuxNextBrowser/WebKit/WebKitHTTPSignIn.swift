import Foundation

/// One HTTP sign-in challenge of a WebKit tab: a login the user chose to
/// remember answers the first try (Keychain read off the main actor); else
/// the tab's sign-in sheet asks, and a checked Remember saves the answer, an
/// unchecked one forgets the saved login (Keychain write off the main actor).
struct WebKitHTTPSignIn {
    let memory: BrowserHTTPSignInMemory?
    let key: BrowserHTTPCredentialKey
    let failures: Int
    let space: URLProtectionSpace
    /// The tab's prompt queue (`WebKitTab.enqueuePrompt`).
    let ask: (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void

    func run(_ completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let memory = memory, key = key, failures = failures
        // task-owner: one Keychain read off the main actor, then the answer; ends with it
        Task {
            let remembered = await Task.detached { memory?.remembered(key, failures: failures) }.value
            if let remembered {
                return completionHandler(.useCredential,
                                         URLCredential(user: remembered.user, password: remembered.password, persistence: .forSession))
            }
            askUser(completionHandler)
        }
    }

    private func askUser(_ completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let memory = memory, key = key, failures = failures
        let kind = BrowserPromptKind.credentials(host: space.host, realm: space.realm.flatMap { $0.isEmpty ? nil : $0 })
        ask(kind, space.host) { response in
            if let memory {
                // task-owner: one Keychain write off the main actor; nothing waits on it
                Task.detached { memory.record(response, for: key, failures: failures) }
            }
            guard let credential = BrowserHTTPAuth.urlCredential(for: response) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, credential)
        }
    }
}
