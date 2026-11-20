@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// A dev build's Chief owner runs in the build's own space. An owner an older build of the same tag started
/// (before `CMUX_BUILD_SPACE` reached it) still calls nightly's cloud data, so the app restarts it, once it is idle,
/// in its build's space. NIGHTLY's shared home is never restarted for this.
@Suite struct ChiefOwnerBuildSpaceTests {
    static func home(_ buildID: String) throws -> ChiefHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ChiefHome(root: root, isolated: false, buildID: buildID)
    }

    @Test func anOwnerWithNoRecordIsInAnotherSpaceForADevBuild() async throws {
        let home = try Self.home("com.cmuxterm.app.debug.my-tag")
        #expect(await ChiefConversationOwner.ownerInOtherSpace(home: home, environment: ["CMUX_BUILD_SPACE": "dev:my-tag"]))
    }

    @Test func anOwnerStartedInThisSpaceIsKept() async throws {
        let home = try Self.home("com.cmuxterm.app.debug.my-tag")
        let environment = ["CMUX_BUILD_SPACE": "dev:my-tag"]
        ChiefConversationOwner.recordBuildSpace(home: home, environment: environment)
        #expect(!(await ChiefConversationOwner.ownerInOtherSpace(home: home, environment: environment)))
        #expect(await ChiefConversationOwner.ownerInOtherSpace(home: home, environment: ["CMUX_BUILD_SPACE": "dev:other"]))
    }

    @Test func ownerEnvironmentRecordsTheSpaceItStartsWith() async throws {
        let home = try Self.home("com.cmuxterm.app.debug.my-tag")
        let environment = await ChiefConversationOwner.ownerEnvironment(home: home, process: ["CMUX_BUILD_SPACE": "dev:my-tag"],
                                                                       resources: nil)
        #expect(environment["CMUX_BUILD_SPACE"] == "dev:my-tag")
        let record = try String(contentsOf: ChiefConversationOwner.buildSpaceRecord(home: home), encoding: .utf8)
        #expect(record == "dev:my-tag")
    }

    @Test func nightlysSharedHomeIsNeverRestartedForASpace() async throws {
        let home = try Self.home(ChiefHome.nightlyBundleID)
        #expect(!(await ChiefConversationOwner.ownerInOtherSpace(home: home, environment: ["CMUX_BUILD_SPACE": "dev:my-tag"])))
    }
}
