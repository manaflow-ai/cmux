@testable import CmuxNextPopups
import Foundation
import Observation

/// A sign-in request as the system hands it over: it records how it ended
/// (completed with a callback URL, or cancelled). Observable, so a test
/// waits on the end it expects instead of polling.
@Observable
final class FakeWebAuthRequest: WebAuthSessionRequest {
    let id = UUID()
    let url: URL
    let isEphemeral: Bool
    let callback: WebAuthCallback
    private(set) var completedURL: URL?
    private(set) var completions = 0
    private(set) var cancels = 0

    init(url: URL = URL(string: "https://accounts.example.com/signin")!, isEphemeral: Bool = false,
         callback: WebAuthCallback = .https(host: "app.example.com", path: "/done")) {
        self.url = url
        self.isEphemeral = isEphemeral
        self.callback = callback
    }

    /// No system matcher here: the callback rule decides, as for a request
    /// whose system callback cmux cannot read.
    func matches(_ url: URL) -> Bool { callback.matches(url) }

    func complete(with url: URL) {
        completedURL = url
        completions += 1
    }

    func cancel() { cancels += 1 }
}
