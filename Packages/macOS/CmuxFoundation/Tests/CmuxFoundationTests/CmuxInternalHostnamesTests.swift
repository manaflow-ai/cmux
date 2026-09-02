import Foundation
import Testing
@testable import CmuxFoundation

/// Covers ``CmuxInternalHostnames``: the slug algorithm shared by the app
/// (building a link) and the CLI (writing `/etc/hosts`), and the managed-block
/// splice that must never disturb the user's own entries.
@Suite("Internal hostnames")
struct CmuxInternalHostnamesTests {
    @Test("Prefers a slugged label over the id; falls back when the label has nothing usable")
    func hostnamePrefersLabel() {
        #expect(CmuxInternalHostnames.hostname(id: "vm-abc123", label: "My Server!") == "my-server.internal")
        #expect(CmuxInternalHostnames.hostname(id: "vm-abc123", label: nil) == "vm-abc123.internal")
        #expect(CmuxInternalHostnames.hostname(id: "vm-abc123", label: "🎉🎉🎉") == "vm-abc123.internal")
    }

    @Test("Slugging lowercases, collapses runs of separators, and trims edges")
    func slugNormalizes() {
        #expect(CmuxInternalHostnames.slug("My  Cool_Server!!") == "my-cool-server")
        #expect(CmuxInternalHostnames.slug("  --leading and trailing--  ") == "leading-and-trailing")
        #expect(CmuxInternalHostnames.slug("") == nil)
        #expect(CmuxInternalHostnames.slug("!!!") == nil)
    }

    @Test("Renders one sorted line per hostname, across machines")
    func rendersSortedBody() {
        let entries = [
            CmuxInternalHostnames.Entry(address: "10.0.0.2", hostnames: ["vm-b.internal", "staging.internal"]),
            CmuxInternalHostnames.Entry(address: "10.0.0.1", hostnames: ["vm-a.internal"]),
        ]
        #expect(CmuxInternalHostnames.renderBlockBody(entries) == [
            "10.0.0.1 vm-a.internal",
            "10.0.0.2 staging.internal",
            "10.0.0.2 vm-b.internal",
        ].joined(separator: "\n"))
    }

    @Test("Appends the managed block to a file with no prior block")
    func appendsWhenAbsent() {
        let current = "127.0.0.1 localhost\n"
        let merged = CmuxInternalHostnames.mergedHostsFile(current: current, body: "10.0.0.1 vm-a.internal")
        #expect(merged.contains("127.0.0.1 localhost"))
        #expect(merged.contains(CmuxInternalHostnames.blockBeginMarker))
        #expect(merged.contains("10.0.0.1 vm-a.internal"))
        #expect(merged.contains(CmuxInternalHostnames.blockEndMarker))
    }

    @Test("Replaces a prior block in place, leaving surrounding lines untouched")
    func replacesExistingBlock() {
        let current = """
        127.0.0.1 localhost
        \(CmuxInternalHostnames.blockBeginMarker)
        10.0.0.1 vm-old.internal
        \(CmuxInternalHostnames.blockEndMarker)
        192.168.1.1 nas.local
        """
        let merged = CmuxInternalHostnames.mergedHostsFile(current: current, body: "10.0.0.2 vm-new.internal")
        #expect(!merged.contains("vm-old.internal"))
        #expect(merged.contains("vm-new.internal"))
        #expect(merged.contains("192.168.1.1 nas.local"))
        #expect(merged.contains("127.0.0.1 localhost"))
    }

    @Test("An empty body removes the block entirely, without leaving a stray blank line")
    func emptyBodyRemovesBlock() {
        let current = """
        127.0.0.1 localhost

        \(CmuxInternalHostnames.blockBeginMarker)
        10.0.0.1 vm-old.internal
        \(CmuxInternalHostnames.blockEndMarker)
        """
        let merged = CmuxInternalHostnames.mergedHostsFile(current: current, body: "")
        #expect(!merged.contains("cmux managed"))
        #expect(!merged.contains("vm-old.internal"))
        #expect(merged == "127.0.0.1 localhost")
    }

    @Test("An already-empty file with an empty body changes nothing")
    func emptyBodyOnFileWithNoBlockIsANoOp() {
        let current = "127.0.0.1 localhost\n"
        #expect(CmuxInternalHostnames.mergedHostsFile(current: current, body: "") == current)
    }

    @Test("A port link is always the raw private address, never the .internal name")
    func directPortURLUsesTheRawAddress() {
        // Deliberately not the `.internal` name: it only resolves once
        // `cmux vpn hosts` has synced `/etc/hosts`, and a link that only
        // sometimes works is worse than one that always does.
        #expect(CmuxInternalHostnames.directPortURL(privateAddress: "10.0.0.2", port: 8000) == "http://10.0.0.2:8000")
    }

    @Test("Brackets an IPv6 address the way every URL scheme requires")
    func directPortURLBracketsIPv6() {
        #expect(
            CmuxInternalHostnames.directPortURL(privateAddress: "fd60:1e5e:6720::3", port: 22)
                == "http://[fd60:1e5e:6720::3]:22"
        )
    }
}
