import Foundation
import Testing
import CmuxNextOnboarding

@MainActor
struct OpenedURLDeliveryTests {
    @Test func launchingCallbackWaitsForReadyAppAndRunsOnce() throws {
        let delivery = OpenedURLDelivery()
        let callback = try #require(URL(string: "cmux-dev://auth-callback?cmux_auth_state=previous-launch"))
        let next = try #require(URL(string: "https://example.test"))
        var received: [URL] = []
        delivery.receive(callback)
        delivery.receive(next)
        #expect(received.isEmpty)

        delivery.start { received.append($0) }
        #expect(received == [callback, next])
        delivery.start { _ in Issue.record("A repeated start must not replace the live route") }
        delivery.receive(callback)
        #expect(received == [callback, next, callback])
    }
}
