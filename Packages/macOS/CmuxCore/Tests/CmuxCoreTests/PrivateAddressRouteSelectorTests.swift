import CmuxCore
import Testing

@Suite("PrivateAddressRouteSelector")
struct PrivateAddressRouteSelectorTests {
    private let selector = PrivateAddressRouteSelector<String>()

    @Test func ownerWinsAmongMachinesSharingLoopback() {
        let addresses = ["ssh:a": "127.0.0.1", "ssh:b": "127.0.0.1"]
        #expect(selector.machine(forHost: "127.0.0.1", owner: "ssh:b", addresses: addresses) == "ssh:b")
        #expect(selector.machine(forHost: "127.0.0.1", owner: "ssh:a", addresses: addresses) == "ssh:a")
    }

    @Test(arguments: [nil, "cloud-x"] as [String?])
    func loopbackIsNotRoutedForABrowserTheMachineDoesNotOwn(owner: String?) {
        #expect(selector.machine(forHost: "127.0.0.1", owner: owner, addresses: ["ssh:a": "127.0.0.1"]) == nil)
    }

    @Test func uniqueMachineAddressRoutesWithoutAnOwner() {
        let addresses = ["vm1": "10.8.0.5", "vm2": "10.8.0.6"]
        #expect(selector.machine(forHost: "10.8.0.6", owner: nil, addresses: addresses) == "vm2")
    }

    @Test func sharedMachineAddressNeedsAnOwner() {
        let addresses = ["vm1": "10.8.0.5", "vm2": "10.8.0.5"]
        #expect(selector.machine(forHost: "10.8.0.5", owner: nil, addresses: addresses) == nil)
        #expect(selector.machine(forHost: "10.8.0.5", owner: "vm2", addresses: addresses) == "vm2")
    }

    @Test func addressComparisonIgnoresBracketsAndCase() {
        #expect(selector.machine(forHost: "fd00::5", owner: nil, addresses: ["vm": "[FD00::5]"]) == "vm")
    }

    @Test func unmatchedHostIsNotRouted() {
        #expect(selector.machine(forHost: "example.com", owner: "vm", addresses: ["vm": "10.8.0.5"]) == nil)
        #expect(selector.machine(forHost: nil, owner: "vm", addresses: ["vm": "10.8.0.5"]) == nil)
    }
}
