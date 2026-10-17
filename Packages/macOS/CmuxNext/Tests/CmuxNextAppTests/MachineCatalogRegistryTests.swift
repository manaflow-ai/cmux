import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

@MainActor
struct MachineCatalogRegistryTests {
    @Test func blockedRoutesStillObservePolicyReadmission() throws {
        let local = DaemonService()
        let registry = MachineRegistry(local: local)
        let policy = CatalogTestPolicy()
        registry.isFeatureDisabled = { _ in policy.blocked }
        let reach = try ServerReach(hostID: "host_catalog01", installID: "inst_catalog01", name: "Server", route: .unix("/tmp/cmux-catalog-registry.sock"))
        let session = ServerMachineSession(reach: reach, binary: nil,
            paths: .init(root: URL(fileURLWithPath: "/tmp/cmux-catalog-unused")), environment: { [:] }, localIdentity: { nil })
        session.daemon.store.noteHandshake(DaemonIdentity(machineResourceID: "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", generation: "catalog-test"))
        registry.add(session)
        #expect(registry.catalogRecords().count == 1)
        session.daemon.policyBlock.set(true)
        policy.blocked = true
        let invalidated = Mutex(false)
        let blocked = withObservationTracking { registry.catalogRecords() } onChange: { invalidated.withLock { $0 = true } }
        #expect(blocked.isEmpty)
        policy.blocked = false
        #expect(invalidated.withLock { $0 }, "the blocked projection must subscribe to policy readmission")
        session.daemon.policyBlock.set(false)
        #expect(registry.catalogRecords().count == 1)
    }
}
