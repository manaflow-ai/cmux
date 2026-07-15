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

@MainActor
@Test func surfaceRemountPreservesMonotonicInteractionEpoch() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "remounted-terminal"
    let consumer = Task { @MainActor in
        for await _ in store.terminalOutputStream(surfaceID: surfaceID) {}
    }
    let registered = try await pollUntil {
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
    }
    #expect(registered)
    _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})
    let session = try #require(store.terminalScrollSessionsBySurfaceID[surfaceID])
    _ = session.submitInput(.fence)
    let inputEpoch = session.interactionEpoch

    consumer.cancel()
    await consumer.value
    let unmounted = try await pollUntil {
        store.terminalScrollSessionsBySurfaceID[surfaceID] == nil
            && store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil
    }
    #expect(unmounted)

    _ = store.mountTerminalScrollSession(surfaceID: surfaceID, cancelLocal: {})
    let remountedEpoch = try #require(store.currentTerminalInteractionEpoch(surfaceID: surfaceID))

    #expect(remountedEpoch > inputEpoch)
}
