import CmuxSurfaceCatalogModel
import Testing

@Suite("Surface ownership policy")
struct SurfaceOwnershipPolicyTests {
    private let local = SurfaceOwnershipPolicy(cloudMachine: nil)
    private let cloudA = SurfaceOwnershipPolicy(cloudMachine: .cloud("a"))

    @Test("local destinations accept local and cloud sources")
    func localDestinationAcceptsAnySource() {
        #expect(local.allows(source: nil))
        #expect(local.allows(source: .local))
        #expect(local.allows(source: .cloud("foreign")))
    }

    @Test("matching cloud machine is accepted")
    func matchingCloudMachine() {
        #expect(cloudA.allows(source: .cloud("a")))
        #expect(cloudA.allows(resources: [
            SurfaceResourceID(machine: .cloud("a"), kind: .terminal, key: "term_1")
        ]))
    }

    @Test("foreign and local sources are rejected by a cloud destination")
    func foreignCloudMachine() {
        #expect(!cloudA.allows(source: .cloud("b")))
        #expect(!cloudA.allows(source: .local))
    }

    @Test("empty cloud selections are rejected")
    func emptySelection() {
        #expect(local.allows(machines: []))
        #expect(!cloudA.allows(machines: []))
        #expect(!cloudA.allows(resources: []))
    }

    @Test("mixed selections are rejected")
    func mixedSelection() {
        #expect(!cloudA.allows(machines: [.cloud("a"), .cloud("b")]))
        #expect(!cloudA.allows(resources: [
            SurfaceResourceID(machine: .cloud("a"), kind: .browser, key: "browser_1"),
            SurfaceResourceID(machine: .cloud("b"), kind: .display, key: "display:1")
        ]))
    }
}
