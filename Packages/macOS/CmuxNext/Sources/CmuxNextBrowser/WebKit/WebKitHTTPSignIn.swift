import CmuxNextCompat
import Foundation

/// One HTTP sign-in challenge of a WebKit tab: a login the user chose to
/// remember answers the first try, from memory when the App's list knows it
/// (``BrowserHTTPSignInMemory/cached(_:failures:)``: no Keychain call), else
/// from a Keychain read on the app's system lane; without one the tab's
/// sign-in sheet asks, and a checked Remember saves the answer, an unchecked
/// one forgets the saved login (memory at once, the Keychain write on the
/// system lane). Without lanes (tests) the Keychain is never read or written.
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
        switch memory?.cached(key, failures: failures) ?? .absent {
        case .secret(let remembered):
            return completionHandler(.useCredential, URLCredential(user: remembered.user, password: remembered.password, persistence: .forSession))
        case .absent:
            return askUser(completionHandler)
        case .unknown:
            break
        }
        // task-owner: one Keychain read on the system lane, then the answer; ends with it
        // main-hop-allow: the read runs on the system lane; its resume answers WebKit's challenge or asks through the tab's prompt queue, main-actor state that is not Sendable
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
            if let memory, let change = memory.change(after: response, failures: failures) {
                memory.apply(change, for: key)
                if let lanes { Self.write(change, in: memory, key: key, on: lanes) }
            }
            guard let credential = BrowserHTTPAuth.urlCredential(for: response) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, credential)
        }
    }

    /// Saves (a checked Remember) or forgets the answer in the Keychain on the system lane, from off the main actor.
    private nonisolated static func write(_ change: BrowserHTTPSignInMemory.Change, in memory: BrowserHTTPSignInMemory,
                                          key: BrowserHTTPCredentialKey, on lanes: any MayBlockRunner) {
        // task-owner: one Keychain write on the system lane; nothing waits on it
        Task { _ = try? await lanes.runSystem(.bestEffort) { memory.write(change, for: key) } }
    }
}
