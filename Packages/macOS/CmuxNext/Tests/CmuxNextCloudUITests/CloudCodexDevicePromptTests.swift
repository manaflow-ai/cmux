import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDesign
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudCodexDevicePromptTests {
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
        let presentation = CloudCodexDevicePrompt(center: center, open: { _ in Issue.record("Cancelled prompt opened a browser") })
        let task = Task { await presentation.present(prompt, in: .app) }
        var iterator = events.stream.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        #expect(await task.value == false)
        #expect(center.records.isEmpty)
    }

    @Test func alreadyCancelledOperationNeverShowsACode() async throws {
        let prompt = try makePrompt()
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let presentation = CloudCodexDevicePrompt(center: center, open: { _ in Issue.record("Cancelled prompt opened a browser") })
        let task = Task { await presentation.present(prompt, in: .app) }
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
        let presentation = CloudCodexDevicePrompt(center: center, open: { opened.append($0) })
        #expect(await presentation.present(prompt, in: .app))
        #expect(opened == [prompt.verificationURL])
        #expect(shown == 2)
        #expect(center.records.isEmpty)
    }
}
