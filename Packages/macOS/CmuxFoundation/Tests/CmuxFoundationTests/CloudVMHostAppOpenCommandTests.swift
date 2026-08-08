import Foundation
import Testing

@testable import CmuxFoundation

/// `vm.open_local` lets a CLI inside a remote workspace ask the Mac app to run
/// a Cloud VM attach locally (https://github.com/manaflow-ai/cmux/issues/9657).
/// The caller is remote, so the parameters it sends are a trust boundary: the
/// app builds argv from this type and must never splice caller text into a
/// command.
struct CloudVMHostAppOpenCommandTests {
    @Test func baseIsRequestedWithoutAVMIdentifier() {
        #expect(CloudVMHostAppOpenCommand.base.socketParameters.isEmpty)
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: [:]) == .base)
        // Base is opened through the app's own workspace-owning action, not argv.
        #expect(CloudVMHostAppOpenCommand.base.cliArguments == nil)
    }

    @Test func perVMCommandsRoundTripThroughSocketParameters() {
        let shell = CloudVMHostAppOpenCommand.shell(vmID: "vm-abc_123")
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: shell.socketParameters) == shell)
        #expect(shell.cliArguments == ["vm", "shell", "vm-abc_123"])

        let ssh = CloudVMHostAppOpenCommand.ssh(vmID: "vm-abc_123")
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ssh.socketParameters) == ssh)
        #expect(ssh.cliArguments == ["vm", "ssh", "vm-abc_123"])
    }

    @Test(arguments: [
        "vm; rm -rf /",
        "vm id",
        "vm$(whoami)",
        "vm`id`",
        "vm\nid",
        "--workspace",
        "",
        "   ",
    ])
    func malformedIdentifiersAreRejectedRatherThanReachingArgv(rawID: String) {
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ["id": rawID]) == nil)
    }

    @Test func nonStringIdentifiersAreRejected() {
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ["id": 7]) == nil)
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ["id": ["a"]]) == nil)
    }

    @Test func overlongIdentifiersAreRejected() {
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ["id": String(repeating: "a", count: 129)]) == nil)
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ["id": String(repeating: "a", count: 128)]) != nil)
    }

    @Test func surroundingWhitespaceIsTrimmedBeforeValidation() {
        #expect(CloudVMHostAppOpenCommand.from(socketParameters: ["id": "  vm-1  "]) == .shell(vmID: "vm-1"))
    }
}
