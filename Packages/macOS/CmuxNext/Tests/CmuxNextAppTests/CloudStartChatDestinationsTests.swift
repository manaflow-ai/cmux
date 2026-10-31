import Testing
@testable import CmuxNextApp

/// A retry of a Cloud send whose answer was lost goes back to the machine its first try picked
/// (whose daemon knows the tab's creation key), never to another machine that would start a second chat.
@Suite
@MainActor
struct CloudStartChatDestinationsTests {
    @Test func aRetryOfTheSameSendNamesTheMachineItsFirstTryPicked() {
        let destinations = CloudStartChat.Destinations()
        #expect(destinations.machine(for: "send-1") == nil)
        destinations.record("machine-a", for: "send-1")
        destinations.record("machine-b", for: "send-2")
        #expect(destinations.machine(for: "send-1") == "machine-a")
        #expect(destinations.machine(for: "send-2") == "machine-b")
        // A later try of the same send that reached another machine (the first was gone) is the one kept.
        destinations.record("machine-c", for: "send-1")
        #expect(destinations.machine(for: "send-1") == "machine-c")
    }

    @Test func onlyTheNewestSendsAreKept() {
        let destinations = CloudStartChat.Destinations()
        for index in 0..<40 { destinations.record("machine-\(index)", for: "send-\(index)") }
        #expect(destinations.machine(for: "send-0") == nil)
        #expect(destinations.machine(for: "send-7") == nil)
        #expect(destinations.machine(for: "send-8") == "machine-8")
        #expect(destinations.machine(for: "send-39") == "machine-39")
    }
}
