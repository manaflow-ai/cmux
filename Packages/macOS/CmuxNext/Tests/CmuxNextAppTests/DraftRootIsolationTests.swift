import CmuxNextCompat
import CmuxNextControl
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
struct DraftRootIsolationTests {
    @Test func customTaggedReleaseKeepsAnIsolatedDraftIdentity() {
        let release = BuildIdentity(bundleID: "com.cmuxterm.app", bundledTag: nil)
        let custom = BuildIdentity(bundleID: "com.cmuxterm.app", bundledTag: "custom")
        #expect(release.draftIdentityKey == "release")
        #expect(custom.draftIdentityKey == "build-\(custom.key)")
        #expect(custom.draftIdentityKey != release.draftIdentityKey)
        #expect(BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil).draftIdentityKey == "channel-nightly")
        #expect(BuildIdentity(bundleID: "com.cmuxterm.app.nightly.cmux-next", bundledTag: nil).draftIdentityKey == "channel-cmux-next")
        #expect(BuildIdentity(bundleID: "com.cmuxterm.app.debug", bundledTag: "one").draftIdentityKey == "channel-one")
        #expect(BuildIdentity(bundleID: "com.cmuxterm.app.debug", bundledTag: "two").draftIdentityKey == "channel-two")
    }

    @Test(arguments: [
        ("com.cmuxterm.app", nil), ("com.cmuxterm.app.nightly", nil),
        ("com.cmuxterm.app.nightly.cmux-next", nil),
        ("com.cmuxterm.app.debug", "one"), ("com.cmuxterm.app.debug", "two"),
    ] as [(String, String?)])
    func onlyOwnLegacyRootsAreAdopted(_ bundle: String, _ tag: String?) async throws {
        let build = BuildIdentity(bundleID: bundle, bundledTag: tag)
        let launch = LaunchIdentity(bundleID: bundle, tag: tag, socketPath: "", build: build)
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-roots-\(UUID().uuidString)")
        let work = BackgroundWork()
        try await work.run(.userVisible, mayBlock: .files) {
            defer { try? FileManager.checked.removeItem(at: root) }
            let cmux = root.appending(path: "support/cmux")
            let daemon = BuildIdentity(bundleID: nil, bundledTag: nil).acpmuxHome(userHome: root)
            let keys = ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                        "com.cmuxterm.app.debug--one", "com.cmuxterm.app.debug--two", build.key + ".other", build.key + "--other"]
            for key in keys {
                for parent in [cmux, daemon] {
                    try FileManager.checked.createDirectory(at: parent.appending(path: "builds/\(key)"), withIntermediateDirectories: true)
                }
            }
            let appRoots = SidebarSnapshotFile.legacyDraftDirectories(launch: launch, appSupport: cmux)
            let daemonRoots = build.legacyAcpmuxDraftHomes(userHome: root)
            for (candidates, parent) in [(appRoots, cmux), (daemonRoots, daemon)] {
                let builds = parent.appending(path: "builds")
                let selected = candidates.filter { $0.deletingLastPathComponent().path == builds.path }
                #expect(Set(selected.map(\.path)) == [builds.appending(path: build.key).path])
            }
        }
    }
}
