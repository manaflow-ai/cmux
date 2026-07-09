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

@Suite("Dock extension shell commands")
struct DockExtensionShellCommandTests {
    @Test func safeArgumentsStayBare() {
        #expect(DockExtensionBuildStep(command: ["npx", "--yes", "./run.sh"]).shellCommand == "npx --yes ./run.sh")
        #expect(DockExtensionBuildStep(command: ["a=b", "x:y", "v1.2,3"]).shellCommand == "a=b x:y v1.2,3")
    }

    @Test func unsafeArgumentsAreSingleQuoted() {
        #expect(DockExtensionBuildStep(command: ["echo", "hello world"]).shellCommand == "echo 'hello world'")
        #expect(["it's"].dockExtensionShellCommand == "'it'\\''s'")
        #expect(["$HOME"].dockExtensionShellCommand == "'$HOME'")
        #expect(["a;b"].dockExtensionShellCommand == "'a;b'")
        #expect([""].dockExtensionShellCommand == "''")
    }

    @Test func paneAndStepRenderTheSameWay() {
        let argv = ["./bin/tui", "--flag", "two words"]
        let pane = DockExtensionPane(id: "main", title: "Main", command: argv)
        #expect(pane.shellCommand == DockExtensionBuildStep(command: argv).shellCommand)
    }
}

@Suite("Consent fingerprint")
struct DockExtensionConsentFingerprintTests {
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
        let first = manifest(env: ["A": "1", "B": "2"]).consentFingerprint(pinnedSha: "abc")
        let second = manifest(env: ["B": "2", "A": "1"]).consentFingerprint(pinnedSha: "abc")
        #expect(first == second)
        #expect(first.count == 64)
    }

    @Test func changesWhenConsentedSurfaceChanges() {
        let base = manifest().consentFingerprint(pinnedSha: "abc")
        #expect(base != manifest().consentFingerprint(pinnedSha: "def"))
        #expect(base != manifest(command: ["run", "-x"]).consentFingerprint(pinnedSha: "abc"))
        #expect(base != manifest().consentFingerprint(pinnedSha: nil))
    }
}

@Suite("DockExtensionFingerprint platform gating")
struct DockExtensionFingerprintPlatformTests {
    private func manifest(panePlatforms: [String]?) -> DockExtensionManifest {
        DockExtensionManifest(
            manifestVersion: 1,
            id: "x",
            name: "X",
            version: "1",
            panes: [DockExtensionPane(
                id: "main", title: "Main", command: ["run"], platforms: panePlatforms
            )]
        )
    }

    @Test func platformListChangesFingerprint() {
        // A pane flipped from linux-only to macOS must demand re-consent: it
        // was hidden from the consent sheet when originally approved.
        let hidden = manifest(panePlatforms: ["linux"]).consentFingerprint(pinnedSha: "abc")
        let exposed = manifest(panePlatforms: ["macos"]).consentFingerprint(pinnedSha: "abc")
        let all = manifest(panePlatforms: nil).consentFingerprint(pinnedSha: "abc")
        #expect(hidden != exposed)
        #expect(hidden != all)
        #expect(exposed != all)
    }
}
