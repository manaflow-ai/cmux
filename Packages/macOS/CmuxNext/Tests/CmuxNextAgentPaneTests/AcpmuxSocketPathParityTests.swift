import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The acpmux socket every host and client resolves, against the shared cases
/// (cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json) that the
/// Rust policy, cmux-tui, the brain host and the Chief run too: a configured
/// `ACPMUX_SOCKET` past the Unix socket limit and a long home reach the same
/// short alias the daemon binds.
struct AcpmuxSocketPathParityTests {
    static let cases: [String: Any] = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }()

    @Test func defaultSocketsMatchTheSharedCases() throws {
        let sockets = try #require(Self.cases["sockets"] as? [[Any]])
        #expect(!sockets.isEmpty)
        for row in sockets {
            let home = URL(fileURLWithPath: try #require(row[0] as? String), isDirectory: true)
            let uid = UInt32(try #require(row[1] as? Int))
            #expect(AcpmuxEnvironment.defaultSocketPath(home: home, uid: uid) == row[2] as? String)
        }
    }

    /// The local model relay's admin socket (cx-qukj2): a long tagged home whose
    /// `router/router.sock` passes the Unix socket limit reaches the short alias the relay binds,
    /// never a path `NWEndpoint.unix` traps on.
    @Test func routerSocketsMatchTheSharedCases() throws {
        let sockets = try #require(Self.cases["router_sockets"] as? [[Any]])
        #expect(!sockets.isEmpty)
        for row in sockets {
            let home = URL(fileURLWithPath: try #require(row[0] as? String), isDirectory: true)
            let uid = UInt32(try #require(row[1] as? Int))
            let got = AcpmuxEnvironment.routerSocketPath(home: home, uid: uid)
            #expect(got == row[2] as? String)
            #expect(got.utf8.count <= AcpmuxEnvironment.maxSocketPathBytes)
        }
    }

    @Test func configuredSocketsMatchTheSharedCases() throws {
        let sockets = try #require(Self.cases["configured_sockets"] as? [[Any]])
        #expect(!sockets.isEmpty)
        for row in sockets {
            let configured = try #require(row[0] as? String)
            let home = URL(fileURLWithPath: try #require(row[1] as? String), isDirectory: true)
            let uid = UInt32(try #require(row[2] as? Int))
            let got = AcpmuxEnvironment.socketPath(configured: configured.isEmpty ? nil : configured, home: home, uid: uid)
            #expect(got == row[3] as? String, "configured \(configured)")
        }
    }
}
