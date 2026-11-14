import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

// The memory is iOS-only (as the Cloud chats screens): these run in the iOS simulator test pass.
#if os(iOS)
/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster/percievably load faster". The Cloud chats sheet opened again draws the machines and
/// chats this run last listed at once, instead of a spinner and "Connecting to <machine> through
/// <Mac>… Up to 40 s" on every open; the Mac's answer takes their place.
@MainActor
@Suite struct CloudChatsMemoryTests {
    static let machine = CloudChatMachine(machineID: "vm1", teamID: "t1", name: "Builder")

    @Test func aSecondOpenHasTheMachinesAndChatsAtOnce() {
        let memory = CloudChatsMemory()
        let location = CloudChatLocation(macID: "mac1", machine: Self.machine)
        #expect(memory.machines(on: "mac1") == nil)
        #expect(memory.chats(at: location) == nil)

        memory.keep(machines: [Self.machine], on: "mac1")
        memory.keep(chats: (0..<250).map { CloudChatListTests.session($0) } + [CloudChatListTests.session(9999, peer: "other")],
                    at: location)
        #expect(memory.machines(on: "mac1") == [Self.machine])
        let kept = memory.chats(at: location)
        // The list's first page, newest first, as the screen draws it; another machine's chats never.
        #expect(kept?.count == CloudChatList.pageSize)
        #expect(kept?.first?.id == "s249")
        #expect(kept?.contains { $0.peer != nil } == false)
        #expect(memory.chats(at: CloudChatLocation(macID: "mac2", machine: Self.machine)) == nil)
    }

    @Test func boundedAndForgottenAtSignOut() {
        let memory = CloudChatsMemory(limit: 2)
        for mac in ["a", "b", "c"] { memory.keep(machines: [Self.machine], on: mac) }
        #expect(memory.machines(on: "a") == nil)
        #expect(memory.machines(on: "c") != nil)
        memory.removeAll()
        #expect(memory.machines(on: "c") == nil)
    }
}
#endif
