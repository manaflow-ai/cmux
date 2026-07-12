import Foundation
import Testing
@testable import CmuxMobileBrowser

@Suite("Mobile diff scheme task lifetime")
struct MobileDiffSchemeTaskLifetimeTests {
    @Test("A stopped request cannot begin a WebKit callback")
    func stoppedRequestRejectsCallback() {
        let lifetime = MobileDiffSchemeTaskLifetime()
        let taskID = ObjectIdentifier(NSObject())
        var callbackRan = false

        lifetime.register(taskID)
        lifetime.stop(taskID)
        let accepted = lifetime.performCallback(taskID) {
            callbackRan = true
        }

        #expect(!accepted)
        #expect(!callbackRan)
    }

    @Test("A finished request cannot receive another callback")
    func finishedRequestRejectsLaterCallback() {
        let lifetime = MobileDiffSchemeTaskLifetime()
        let taskID = ObjectIdentifier(NSObject())
        var callbackCount = 0

        lifetime.register(taskID)
        #expect(lifetime.performCallback(taskID) { callbackCount += 1 })
        lifetime.finish(taskID)
        #expect(!lifetime.performCallback(taskID) { callbackCount += 1 })
        #expect(callbackCount == 1)
    }
}
