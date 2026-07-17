import Foundation
import Testing
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient file RPCs")
struct RemoteDaemonRPCClientFileTests {
    @Test("fs.stat requires an explicit exists boolean")
    func statRequiresExistsBoolean() {
        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonRPCClient.decodeFileStatResult([:])
        }
        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonRPCClient.decodeFileStatResult(["exists": "false"])
        }
    }

    @Test("fs.stat validates existing metadata")
    func statValidatesExistingMetadata() throws {
        let missing = try RemoteDaemonRPCClient.decodeFileStatResult(["exists": false])
        #expect(missing == .missing)

        let file = try RemoteDaemonRPCClient.decodeFileStatResult([
            "exists": true,
            "type": "file",
            "size": NSNumber(value: 42),
        ])
        #expect(file == .existing(kind: .file, size: 42))

        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonRPCClient.decodeFileStatResult([
                "exists": true,
                "type": "file",
                "size": NSNumber(value: -1),
            ])
        }
    }
}
