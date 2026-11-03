import CmuxNextCloud
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudCodexDeviceRecoveryTests {
    private func makePrompt() throws -> CloudCodexLoginPrompt {
        CloudCodexLoginPrompt(verificationURL: try #require(URL(string: "https://example.com/device")), userCode: "DEMO-CODE")
    }

    @Test func cancellationDismissesAnOpenCodeAndReturnsFalse() async throws {
        let prompt = try makePrompt()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let events = AsyncStream.makeStream(of: Void.self)
        let token = center.observe { event in
            if case .opened = event { events.continuation.yield(()) }
        }
        defer { center.stopObserving(token); events.continuation.finish() }
        let task = Task {
            await CloudPresenter.presentCodexDeviceCode(prompt, in: .app, center: center,
                open: { _ in Issue.record("Cancelled prompt opened a browser") })
        }
        var iterator = events.stream.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        #expect(await task.value == false)
        #expect(center.records.isEmpty)
    }

    @Test func alreadyCancelledOperationNeverShowsACode() async throws {
        let prompt = try makePrompt()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let task = Task {
            await CloudPresenter.presentCodexDeviceCode(prompt, in: .app, center: center,
                open: { _ in Issue.record("Cancelled prompt opened a browser") })
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(center.records.isEmpty)
    }

    @Test func openingBrowserKeepsCodeAvailableUntilExplicitConfirmation() async throws {
        let prompt = try makePrompt()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var opened: [URL] = []
        var shown = 0
        let token = center.observe { event in
            guard case .opened(let record) = event else { return }
            shown += 1
            center.press(record.id, button: shown == 1 ? "open" : "signedIn")
        }
        defer { center.stopObserving(token) }
        #expect(await CloudPresenter.presentCodexDeviceCode(prompt, in: .app, center: center,
                                                          open: { opened.append($0) }))
        #expect(opened == [prompt.verificationURL])
        #expect(shown == 2)
        #expect(center.records.isEmpty)
    }
}
