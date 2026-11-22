import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The acpmux daemon a DEV build starts reads the build's own settings file and host budget: its allow-listed
/// environment carries the build's ``BuildStatePaths/environment`` from the app's.
@Suite struct AcpmuxDevBuildStateTests {
    @Test func acpmuxGetsTheBuildsFiles() throws {
        let root = URL(fileURLWithPath: "/tmp/adbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let files = ["CMUX_NEXT_CONFIG_FILE": "/x/config/cmux-next.json", "ACPMUX_HOST_BUDGET": "/x/config/host-budget.json",
                     "CMUX_NEXT_CLOUD_SECRETS_FILE": "/x/config/cloud-secrets.json"]
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin,
            environment: files.merging(["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path]) { $1 },
            executableOverride: nil
        ))
        for (key, value) in files {
            #expect(environment.childEnvironment[key] == value, "\(key)")
        }
    }
}
