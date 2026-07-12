import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Test func staleStreamTerminationDoesNotUnmountReplacementSink() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let oldConsumer = Task { @MainActor in
        for await _ in store.terminalOutputStream(surfaceID: surfaceID) {}
    }
    let oldRegistered = try await pollUntil {
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
    }
    #expect(oldRegistered)
    let oldToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])

    var currentIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let currentToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    #expect(currentToken != oldToken)

    oldConsumer.cancel()
    await oldConsumer.value
    let oldConsumerSettled = try await pollUntil {
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] == currentToken
    }
    #expect(oldConsumerSettled)

    #expect(store.terminalOutputStreamTokensBySurfaceID[surfaceID] == currentToken)
    let accepted = store.deliverTerminalBytes(Data("replacement-live".utf8), surfaceID: surfaceID)
    #expect(accepted)
    if accepted {
        let chunk = try #require(await currentIterator.next())
        #expect(String(data: chunk.data, encoding: .utf8) == "replacement-live")
    }
}
