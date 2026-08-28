import Foundation
import Testing

@testable import CmuxTopMemory

struct CmuxTopMemoryOwnershipTests {
    @Test func detachedTTYProcessRemainsAmbiguous() {
        let surfaceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let tty: Int64 = 42
        let app = record(pid: 10, parentPID: 1, path: "/Applications/cmux.app/Contents/MacOS/cmux")
        let shell = record(
            pid: 20,
            parentPID: 1,
            path: nil,
            ttyDevice: tty,
            workspaceID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            surfaceID: surfaceID,
            attributionReason: "cmux-environment",
            processGroupID: 50
        )
        let detached = record(
            pid: 30,
            parentPID: 1,
            path: "/tmp/cmux",
            ttyDevice: tty,
            processGroupID: 30
        )

        let ownership = CmuxTopProcessOwnershipResolver(processes: [app, shell, detached]).resolve(
            surfaceID: surfaceID,
            ttyDevice: tty,
            applicationPID: app.pid,
            trustedExecutablePaths: [
                "/Applications/cmux.app/Contents/MacOS/cmux",
                "/Applications/cmux.app/Contents/Resources/bin/cmux"
            ]
        )

        #expect(ownership.ownedTTYProcessIDs == [20])
        #expect(ownership.ambiguousTTYProcessIDs == [30])
        #expect(ownership.reasonByProcessID[30] == CmuxTopMemoryOwnershipReason.sameTTYUnproven.rawValue)
    }

    @Test func launchdParentedWebKitRootCanBeRepresentedAsExplicitAttribution() {
        let workspaceID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let surfaceID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let owner = CmuxTopMemoryOwner(
            workspaceID: workspaceID,
            workspaceRef: "workspace:web",
            paneID: nil,
            paneRef: nil,
            surfaceID: surfaceID,
            surfaceRef: "surface:web",
            surfaceType: "browser"
        )
        let result = CmuxTopMemoryAttributionResolver().resolve(nodes: [
            CmuxTopMemoryAttributionNode(
                owner: owner,
                defaultReason: CmuxTopMemoryOwnershipReason.webViewRoot.rawValue,
                processIDs: [900]
            )
        ])

        #expect(result[900]?.reason == CmuxTopMemoryOwnershipReason.webViewRoot.rawValue)
        #expect(result[900]?.owner.surfaceID == surfaceID)
    }

    private func record(
        pid: Int,
        parentPID: Int,
        path: String? = nil,
        ttyDevice: Int64? = nil,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        attributionReason: String? = nil,
        processGroupID: Int? = nil
    ) -> CmuxTopMemoryProcessRecord {
        CmuxTopMemoryProcessRecord(
            pid: pid,
            parentPID: parentPID,
            path: path,
            ttyDevice: ttyDevice,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            attributionReason: attributionReason,
            processGroupID: processGroupID
        )
    }
}
