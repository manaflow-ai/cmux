import Foundation
import Testing
@testable import CmuxMobileBrowser

@Suite("Mobile diff scheme task lifetime")
struct MobileDiffSchemeTaskLifetimeTests {
    @Test("A stopped request cannot begin a WebKit callback")
    func stoppedRequestRejectsCallback() async {
        let lifetime = MobileDiffSchemeTaskLifetime()
        let taskID = ObjectIdentifier(NSObject())

        await lifetime.register(taskID)
        await lifetime.stop(taskID)
        let accepted = await lifetime.performCallback(taskID) {}

        #expect(!accepted)
    }

    @Test("A finished request cannot receive another callback")
    func finishedRequestRejectsLaterCallback() async {
        let lifetime = MobileDiffSchemeTaskLifetime()
        let taskID = ObjectIdentifier(NSObject())

        await lifetime.register(taskID)
        let accepted = await lifetime.performCallback(taskID) {}
        await lifetime.finish(taskID)
        let acceptedAfterFinish = await lifetime.performCallback(taskID) {}

        #expect(accepted)
        #expect(!acceptedAfterFinish)
    }

    @Test("A reentrant stop does not deadlock callback delivery")
    func reentrantStopReturnsAndRejectsLaterCallbacks() async {
        let lifetime = MobileDiffSchemeTaskLifetime()
        let taskID = ObjectIdentifier(NSObject())

        await lifetime.register(taskID)
        let accepted = await lifetime.performCallback(taskID) {
            Task { await lifetime.stop(taskID) }
        }
        await lifetime.stop(taskID)
        let acceptedAfterStop = await lifetime.performCallback(taskID) {}

        #expect(accepted)
        #expect(!acceptedAfterStop)
    }
}
