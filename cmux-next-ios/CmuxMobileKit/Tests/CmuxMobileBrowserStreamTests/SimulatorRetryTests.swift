#if os(iOS)
import CmuxMobileTransport
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileBrowserStream

/// A failed open is opened again on its own (the page's AutoRetry runs
/// ``StreamedBrowserModel/reconnectAnswered(within:)``), never behind a Retry button;
/// a refusal is not retried.
@MainActor @Suite struct SimulatorRetryTests {
    /// Fails its first open with `error`, then opens like ``FakeOpener``.
    final class FailingOnce: @unchecked Sendable {
        let opener = FakeOpener()
        let lock = NSLock()
        var error: LinkError?
        var attempts = 0

        init(_ error: LinkError) { self.error = error }

        func open(_ sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
            let failure: LinkError? = lock.withLock {
                attempts += 1
                defer { error = nil }
                return error
            }
            if let failure { throw failure }
            return try await opener.openBrowser(tab: "simulator", url: nil, sink: sink)
        }
    }

    @Test func aFailedOpenOpensAgainOnItsOwn() async throws {
        let fake = FailingOnce(LinkError(code: "timeout", message: "timed out"))
        let model = StreamedBrowserModel(tab: "simulator", url: nil) { sink in try await fake.open(sink) }
        let rig = RedialTests()
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        model.reconnect()
        await rig.until { model.openFailed }
        #expect(model.openFailed)
        #expect(!model.canReopen, "no Reopen for a passing failure")
        await model.reconnectAnswered(within: .seconds(1))
        await rig.until { fake.opener.tabs.count == 1 }
        #expect(fake.opener.tabs == ["simulator"])
        #expect(!model.openFailed)
        model.setVisible(false)
        model.close()
    }

    @Test func aRefusedOpenIsNotRetried() async throws {
        let fake = FailingOnce(LinkError(code: "forbidden", message: "only http, https and about:blank load"))
        let model = StreamedBrowserModel(tab: "simulator", url: nil) { sink in try await fake.open(sink) }
        let rig = RedialTests()
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        model.reconnect()
        await rig.until { fake.lock.withLock { fake.attempts } == 1 && model.phase != .connecting }
        #expect(!model.openFailed)
        model.setVisible(false)
        model.close()
    }
}
#endif
