import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A test never reaches the person's own acpmux daemon (cmux12s, 2026-10-26): `cmux-next swift
/// test` resolved `~/.acpmux` from a process environment with no `ACPMUX_HOME`, handed the mini's
/// daemon off and cycled daemons there for the rest of the run. In a test process, a home in the
/// account's `~/.acpmux` (or a build home under it) now resolves to nothing.
struct AcpmuxTestHomeGuardTests {
    static let executable = URL(fileURLWithPath: "/usr/bin/true")

    /// What a test that names no home resolves, with every other default left as the app's.
    static func resolve(build: BuildIdentity?, _ environment: [String: String]) -> AcpmuxEnvironment? {
        AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: nil, environment: environment,
                                  isExecutable: { _ in true }, executableOverride: executable, teamIdentifier: nil)
    }

    @Test func aTestThatNamesNoHomeNeverGetsThePersonsDaemon() {
        #expect(Self.resolve(build: nil, [:]) == nil)
        #expect(Self.resolve(build: BuildIdentity(bundleID: "com.cmuxterm.app.debug.guard", bundledTag: nil), [:]) == nil)
        let persons = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".acpmux").path
        #expect(Self.resolve(build: nil, ["ACPMUX_HOME": persons]) == nil)
    }

    @Test func aTestWithItsOwnHomeGetsIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-guard-\(UUID().uuidString)")
        let resolved = try #require(Self.resolve(build: nil, ["ACPMUX_HOME": home.path]))
        #expect(resolved.home.path == home.path)
        #expect(resolved.childEnvironment["ACPMUX_HOME"] == home.path)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-root-\(UUID().uuidString)")
        let rooted = try #require(Self.resolve(build: nil, ["CMUX_NEXT_ACPMUX_ROOT": root.path]))
        #expect(rooted.home.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test func thisProcessCountsAsATest() {
        #expect(AcpmuxEnvironment.testProcessPersonsHome != nil)
        #expect(AcpmuxEnvironment.isTestProcess(name: "swiftpm-testing-helper", environment: [:]))
        #expect(AcpmuxEnvironment.isTestProcess(name: "xctest", environment: [:]))
        #expect(AcpmuxEnvironment.isTestProcess(name: "cmux", environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
        #expect(!AcpmuxEnvironment.isTestProcess(name: "cmux", environment: [:]))
    }

    @Test func onlyTheAccountsAcpmuxTreeIsRefused() {
        let person = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let refused = ["/Users/someone/.acpmux", "/Users/someone/.acpmux/", "/Users/someone/.acpmux/builds/com.cmuxterm.app.debug.x"]
        for path in refused {
            #expect(AcpmuxEnvironment.isPersonsAcpmuxHome(URL(fileURLWithPath: path), personsHome: person), "\(path)")
        }
        for path in ["/Users/someone/.acpmux-test", "/tmp/job/acpmux-home", "/Users/other/.acpmux"] {
            #expect(!AcpmuxEnvironment.isPersonsAcpmuxHome(URL(fileURLWithPath: path), personsHome: person), "\(path)")
        }
    }
}
