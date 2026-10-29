import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The refusal bit lives in a `Mutex<Bool>`, so the delegate is plainly
/// `Sendable`: URLSession's delegate queue writes it while the request's owner reads it.
struct RedirectMethodPreservingDelegateRefusalTests {
    /// Calls the redirect callback for one unresumed POST and returns the request it hands back.
    private static func redirect(
        _ delegate: RedirectMethodPreservingDelegate,
        from source: URL,
        to target: URL,
        status: Int
    ) throws -> URLRequest? {
        var original = URLRequest(url: source)
        original.httpMethod = "POST"
        original.httpBody = Data("{}".utf8)
        original.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: original)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(url: source, statusCode: status, httpVersion: nil, headerFields: nil))
        var proposed = URLRequest(url: target)
        proposed.httpMethod = "GET"
        var handed: URLRequest?
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposed,
            completionHandler: { handed = $0 }
        )
        return handed
    }

    @Test func sameOriginRedirectKeepsTheMutationAndDoesNotRefuse() throws {
        let delegate = RedirectMethodPreservingDelegate()
        let source = try #require(URL(string: "https://push.example.test/register"))
        let target = try #require(URL(string: "https://push.example.test/v2/register"))

        let handed = try #require(try Self.redirect(delegate, from: source, to: target, status: 302))

        #expect(handed.httpMethod == "POST")
        #expect(handed.httpBody == Data("{}".utf8))
        #expect(handed.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(!delegate.refusedRedirect)
    }

    @Test func crossOriginRedirectIsRefusedAndRecorded() throws {
        let delegate = RedirectMethodPreservingDelegate()
        let source = try #require(URL(string: "https://push.example.test/register"))
        let target = try #require(URL(string: "https://other.example.test/register"))

        #expect(try Self.redirect(delegate, from: source, to: target, status: 302) == nil)
        #expect(delegate.refusedRedirect)
    }

    /// A race probe for concurrent writes and reads of the refusal bit: it can fail only under
    /// `swift test --sanitize=thread`, because the group join already orders the final read.
    @Test func concurrentRefusalWritesAndReadsAreRaceFree() async throws {
        let delegate = RedirectMethodPreservingDelegate()
        let source = try #require(URL(string: "https://push.example.test/send"))
        let target = try #require(URL(string: "https://push.example.test/send"))

        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<32 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        // A mutating 303 is refused: the body-less GET cannot acknowledge it.
                        _ = try? Self.redirect(delegate, from: source, to: target, status: 303)
                    }
                    return delegate.refusedRedirect
                }
            }
            for await _ in group {}
        }

        #expect(delegate.refusedRedirect)
    }
}
