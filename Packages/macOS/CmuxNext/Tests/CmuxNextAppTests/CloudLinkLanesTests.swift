@testable import CmuxNextCloud
import Foundation
import Testing

/// A Cloud terminal lagged while a browser tab loaded a machine port (#25595): the link ran
/// `--lanes single`, so keystrokes shared one WebSocket with terminal output and forwarded browser
/// bytes, and a key waited behind every bulk frame already queued in that socket. `auto` gives the
/// interactive lane its own WebSocket (`lane_bindings` in cmux-remote).
struct CloudLinkLanesTests {
    private let paths = CloudPaths(root: URL(fileURLWithPath: "/tmp/cmux-cloud-lanes-test", isDirectory: true))

    private func value(of flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    @Test(arguments: [false, true])
    func everyLinkKeepsKeystrokesOnTheirOwnLane(invited: Bool) {
        let arguments = CloudMachineLink.connectArguments(
            route: "ws://10.0.0.2:1337/v1/link", deviceName: "Mac", paths: paths, machineID: "vm-1",
            inviteFile: invited ? URL(fileURLWithPath: "/tmp/invite") : nil, trustedCarrier: !invited, hubSocket: "/tmp/hub.sock"
        )
        #expect(value(of: "--lanes", in: arguments) == "auto")
        #expect(arguments.filter { $0 == "--lanes" }.count == 1)
        #expect(Array(arguments.prefix(3)) == ["remote", "connect", "ws://10.0.0.2:1337/v1/link"])
        #expect(value(of: "--wireguard-hub", in: arguments) == "/tmp/hub.sock")
        #expect(value(of: "--local-socket", in: arguments) == paths.linkSocket(machineID: "vm-1"))
        #expect(arguments.contains("--carrier") == !invited)
        #expect((value(of: "--invite-file", in: arguments) != nil) == invited)
    }

    /// The owner flag (#26323) still reaches the link now that its argv is built here.
    @Test func theOwnerFlagReachesTheLink() {
        let arguments = CloudMachineLink.connectArguments(
            route: "ws://10.0.0.2:1337/v1/link", deviceName: "Mac", paths: paths, machineID: "vm-1",
            inviteFile: nil, trustedCarrier: true, hubSocket: "/tmp/hub.sock", vmKind: ["--vm-kind", "owner"]
        )
        #expect(value(of: "--vm-kind", in: arguments) == "owner")
        #expect(Array(arguments.suffix(2)) == ["--wireguard-hub", "/tmp/hub.sock"])
    }
}
