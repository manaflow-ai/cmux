import Testing
@testable import CmuxFoundation

struct CmuxCloudTerminalIdentityTests {
    @Test func canonicalIDWinsOverAStaleKey() {
        let identity = CmuxCloudTerminalIdentity(
            catalogResource: ["id": "vm-one/terminal/term-real", "key": "stale-key"],
            machine: "vm-one"
        )
        #expect(identity?.key == "term-real")
    }

    @Test func acceptsLegacyKeysAndUnqualifiedIDs() {
        #expect(CmuxCloudTerminalIdentity(catalogResource: ["key": " term-old "], machine: "vm-one")?.key == "term-old")
        #expect(CmuxCloudTerminalIdentity(catalogResource: ["id": "term-old"], machine: "vm-one")?.key == "term-old")
        #expect(CmuxCloudTerminalIdentity(catalogResource: ["id": "term-old", "key": "term-explicit"], machine: "vm-one")?.key == "term-explicit")
    }

    @Test func malformedCanonicalIDsCannotFallBackToAKey() {
        for id in ["vm-other/terminal/term-real", "vm-one/browser/term-real", "vm-one/terminal/", "vm-one/terminal/vm-one/terminal/term-real"] {
            #expect(CmuxCloudTerminalIdentity(catalogResource: ["id": id, "key": "term-real"], machine: "vm-one") == nil)
        }
    }

    @Test func rejectsKeysThatAreResourcePathsOrEmpty() {
        #expect(CmuxCloudTerminalIdentity(catalogResource: ["key": "vm-one/terminal/term-real"], machine: "vm-one") == nil)
        #expect(CmuxCloudTerminalIdentity(catalogResource: ["key": " "], machine: "vm-one") == nil)
        #expect(CmuxCloudTerminalIdentity(catalogResource: ["key": "term-real"], machine: "") == nil)
    }
}
