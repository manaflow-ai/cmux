@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The pushed machine state's hand-off rules (`CloudMachineStatePush`): when a frame counts as taken by the Cloud app
/// server, and that socket ids never repeat.
@MainActor @Suite struct CloudMachineStatePushTests {
    @Test func aReplyWithNoCloudServerIsNotAHandOff() {
        #expect(CloudMachineStatePush.handedOff(.object(["servers": .number(1)])))
        #expect(CloudMachineStatePush.handedOff(.object(["servers": .number(2)])))
        // No Cloud app server took it: the machine stays on reads.
        #expect(!CloudMachineStatePush.handedOff(.object(["servers": .number(0)])))
        #expect(!CloudMachineStatePush.handedOff(.object([:])))
        #expect(!CloudMachineStatePush.handedOff(nil))
    }

    @Test func socketIDsOnlyGrowAcrossARecreatedWatch() {
        struct NoToken: Error {}
        let push = CloudMachineStatePush(baseURL: URL(string: "https://platform.invalid")!,
                                         accessToken: { throw NoToken() }, teamID: { nil })
        let machine = CloudMachine(id: "vm_\(String(repeating: "a", count: 20))", status: .running)
        push.watch([machine])
        let first = push.nextSocket()
        // The machine leaves the list and comes back: a new watch, whose sockets never reuse an old id.
        push.watch([])
        push.watch([machine])
        let second = push.nextSocket()
        #expect(second > first)
        push.stop()
        push.watch([machine])
        #expect(push.nextSocket() > second)
        push.stop()
    }
}
