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

        memory.keep(machines: [Self.machine], on: "mac1", readIn: memory.generation)
        memory.keep(chats: (0..<250).map { CloudChatListTests.session($0) } + [CloudChatListTests.session(9999, peer: "other")],
                    at: location, readIn: memory.generation)
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
        for mac in ["a", "b", "c"] { memory.keep(machines: [Self.machine], on: mac, readIn: memory.generation) }
        #expect(memory.machines(on: "a") == nil)
        #expect(memory.machines(on: "c") != nil)
        memory.removeAll()
        #expect(memory.machines(on: "c") == nil)
    }

    /// A machine deleted on the Mac: the Mac's next answer replaces the kept list, so the machine
    /// is gone from the next open too.
    @Test func theMacsAnswerReplacesAKeptMachineItNoLongerLists() {
        let memory = CloudChatsMemory()
        let gone = CloudChatMachine(machineID: "vm2", teamID: "t1", name: "Deleted")
        memory.keep(machines: [Self.machine, gone], on: "mac1", readIn: memory.generation)
        memory.keep(machines: [Self.machine], on: "mac1", readIn: memory.generation)
        #expect(memory.machines(on: "mac1") == [Self.machine])
    }

    /// Privacy: the account's sign-out forgets every kept Cloud machine and chat, so another
    /// account signing in never sees them. This runs the real default `discardKeptChats` of
    /// ``AccountSignOut`` (what RootView's `AccountSignOut().signedOut` runs last), not an injected one.
    @Test func signOutForgetsTheKeptCloudMachinesAndChats() {
        let location = CloudChatLocation(macID: "mac1", machine: Self.machine)
        CloudChatsMemory.shared.keep(machines: [Self.machine], on: "mac1", readIn: CloudChatsMemory.shared.generation)
        CloudChatsMemory.shared.keep(chats: [CloudChatListTests.session(1)], at: location, readIn: CloudChatsMemory.shared.generation)
        AccountSignOut().discardKeptChats()
        #expect(CloudChatsMemory.shared.machines(on: "mac1") == nil)
        #expect(CloudChatsMemory.shared.chats(at: location) == nil)
    }

    /// Privacy: the Mac's answer to a directory read (and a machine's chat list) that began before
    /// the sign-out lands after it, as the screens' `keep` calls do once their await returns. The
    /// memory stays empty, so the next account to sign in never sees the previous one's Cloud
    /// machines or chats. A read begun after the sign-out is kept as usual.
    @Test func aResponseLandingAfterSignOutLeavesTheMemoryEmpty() async {
        let location = CloudChatLocation(macID: "mac1", machine: Self.machine)
        let memory = CloudChatsMemory.shared
        let before = memory.generation
        // The request is in flight; the account signs out (the real default sign-out).
        AccountSignOut().discardKeptChats()
        // The old account's answer arrives late.
        let lateResponse: () async -> [CloudChatMachine] = { await Task.yield(); return [Self.machine] }
        let listed = await lateResponse()
        #expect(memory.keep(machines: listed, on: "mac1", readIn: before) == false)
        #expect(memory.keep(chats: [CloudChatListTests.session(1)], at: location, readIn: before) == false)
        #expect(memory.machines(on: "mac1") == nil)
        #expect(memory.chats(at: location) == nil)

        // The next account's own read keeps its list.
        #expect(memory.keep(machines: [Self.machine], on: "mac1", readIn: memory.generation))
        #expect(memory.machines(on: "mac1") == [Self.machine])
        memory.removeAll()
    }
}
#endif
