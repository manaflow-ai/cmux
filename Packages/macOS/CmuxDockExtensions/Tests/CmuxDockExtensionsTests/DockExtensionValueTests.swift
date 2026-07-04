import Foundation
import Testing
@testable import CmuxDockExtensions

@Suite("DockExtensionVersion")
struct DockExtensionVersionTests {
    @Test func parsesAndCompares() throws {
        let old = try #require(DockExtensionVersion("0.30.0"))
        let new = try #require(DockExtensionVersion("0.31"))
        #expect(old < new)
        #expect(DockExtensionVersion("1.0")! == DockExtensionVersion("1.0.0")!)
        #expect(DockExtensionVersion("1.2.3.4")! > DockExtensionVersion("1.2.3")!)
    }

    @Test func rejectsNonNumericVersions() {
        for input in ["", "1.2.3-beta", "v1.0", "1..2", "1.2.3.4.5", "1234567"] {
            #expect(DockExtensionVersion(input) == nil, "should reject \(input)")
        }
    }
}

@Suite("DockExtensionCommandLine")
struct DockExtensionCommandLineTests {
    @Test func safeArgumentsStayBare() {
        #expect(DockExtensionCommandLine.shellCommand(for: ["npx", "--yes", "./run.sh"]) == "npx --yes ./run.sh")
        #expect(DockExtensionCommandLine.shellCommand(for: ["a=b", "x:y", "v1.2,3"]) == "a=b x:y v1.2,3")
    }

    @Test func unsafeArgumentsAreSingleQuoted() {
        #expect(DockExtensionCommandLine.shellCommand(for: ["echo", "hello world"]) == "echo 'hello world'")
        #expect(DockExtensionCommandLine.quoteIfNeeded("it's") == "'it'\\''s'")
        #expect(DockExtensionCommandLine.quoteIfNeeded("$HOME") == "'$HOME'")
        #expect(DockExtensionCommandLine.quoteIfNeeded("a;b") == "'a;b'")
        #expect(DockExtensionCommandLine.quoteIfNeeded("") == "''")
    }
}

@Suite("DockExtensionFingerprint")
struct DockExtensionFingerprintTests {
    private func manifest(env: [String: String] = ["B": "2", "A": "1"], command: [String] = ["run"]) -> DockExtensionManifest {
        DockExtensionManifest(
            manifestVersion: 1,
            id: "x",
            name: "X",
            version: "1",
            build: [DockExtensionBuildStep(command: ["make"])],
            panes: [DockExtensionPane(id: "main", title: "Main", command: command, env: env)]
        )
    }

    @Test func stableAcrossEnvOrder() {
        let first = DockExtensionFingerprint.compute(pinnedSha: "abc", manifest: manifest(env: ["A": "1", "B": "2"]))
        let second = DockExtensionFingerprint.compute(pinnedSha: "abc", manifest: manifest(env: ["B": "2", "A": "1"]))
        #expect(first == second)
        #expect(first.count == 64)
    }

    @Test func changesWhenConsentedSurfaceChanges() {
        let base = DockExtensionFingerprint.compute(pinnedSha: "abc", manifest: manifest())
        #expect(base != DockExtensionFingerprint.compute(pinnedSha: "def", manifest: manifest()))
        #expect(base != DockExtensionFingerprint.compute(pinnedSha: "abc", manifest: manifest(command: ["run", "-x"])))
        #expect(base != DockExtensionFingerprint.compute(pinnedSha: nil, manifest: manifest()))
    }
}
