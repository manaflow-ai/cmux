import CmuxCloud
import Foundation
import Testing

@Suite("Cloud machine create invocation")
struct CloudMachineCreateArgumentParserTests {
    @Test("parses supported create arguments")
    func parsesSupportedCreate() throws {
        let workspace = UUID()
        let invocation = try #require(CloudMachineCreateArgumentParser().parse(arguments: [
            "vm", "new", "--desktop", "--size", "8192", "--workspace", workspace.uuidString
        ]))
        #expect(invocation.kind == .desktop)
        #expect(invocation.memoryMb == 8192)
        #expect(invocation.workspaceID == workspace)
    }

    @Test("rejects unsupported lifecycle commands")
    func rejectsUnsupportedCommands() {
        let parser = CloudMachineCreateArgumentParser()
        #expect(parser.parse(arguments: ["vm", "base", "open"]) == nil)
        #expect(parser.parse(arguments: ["vm", "new", "--image", "legacy"]) == nil)
    }

    @Test("idempotency keys distinguish operation identities")
    func idempotencyKeysAreStableAndDistinct() {
        let parser = CloudMachineCreateArgumentParser()
        let first = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(parser.idempotencyKey(operationID: first) == "app-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(parser.idempotencyKey(operationID: first) != parser.idempotencyKey(operationID: UUID()))
    }
}
