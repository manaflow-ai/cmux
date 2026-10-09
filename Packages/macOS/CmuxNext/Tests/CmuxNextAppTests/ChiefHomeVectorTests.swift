import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// The app and the `cmux chief` CLI open the same Chief home: both read
/// schemas/chief-home/vectors.json (the CLI in cmux-tui cli/chief/tests.rs).
/// On 2026-10-09 an agent-preflight app (CMUX_NEXT_NO_ACTIVATE=1) owned
/// cmux-chief-9c63c459 while `cmux chief` in its terminal resolved
/// cmux-chief-b902d10e, the default home, and found no session.
@Suite struct ChiefHomeVectorTests {
    struct Vectors: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let name: String
        let user_home: String
        let tag: String?
        let environment: [String: String]
        let root: String
        let session: String
        let isolated: Bool?
    }

    static func vectors() throws -> [Case] {
        // Tests/CmuxNextAppTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appending(path: "schemas/chief-home/vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data).cases
    }

    @Test func theAppResolvesEveryVector() throws {
        let cases = try Self.vectors()
        #expect(cases.count >= 6)
        for vector in cases {
            let home = ChiefHome.resolve(tag: vector.tag, environment: vector.environment,
                                         userHome: URL(fileURLWithPath: vector.user_home, isDirectory: true))
            #expect(home.root.path == vector.root, "\(vector.name)")
            #expect(home.session == vector.session, "\(vector.name)")
            if let isolated = vector.isolated { #expect(home.isolated == isolated, "\(vector.name)") }
        }
    }

    /// The app's terminals name the app's Chief home, so `cmux chief` in
    /// them opens the app's Chief whatever made the app isolated.
    @Test func theAppsTerminalsCarryItsChiefHome() {
        let launch = LaunchIdentity(bundleID: "com.cmuxterm.app.next.debug.nxdog80-v1", tag: "nxdog80-v1",
                                    socketPath: "/tmp/t.sock")
        let isolated = AppEnvironment.terminalEnvironment(launch: launch, environment: ["CMUX_NEXT_NO_ACTIVATE": "1"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(isolated["CMUX_CHIEF_HOME"] == home + "/.cmux/chief/isolated/nxdog80-v1")
        let plain = AppEnvironment.terminalEnvironment(launch: launch, environment: [:])
        #expect(plain["CMUX_CHIEF_HOME"] == home + "/.cmux/chief/default")
    }
}
