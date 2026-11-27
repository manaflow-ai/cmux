import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

@Suite struct SurfaceIdentityTests {
    @Test func machineIDRoundTripsThroughItsWireForm() {
        #expect(SurfaceMachineID(rawValue: "local") == .local)
        #expect(SurfaceMachineID(rawValue: "vm-1") == .cloud("vm-1"))
        #expect(SurfaceMachineID.cloud("vm-1").rawValue == "vm-1")
        #expect(SurfaceMachineID.local.isLocal)
        #expect(SurfaceMachineID.cloud("vm-1").cloudMachineID == "vm-1")
    }
}
