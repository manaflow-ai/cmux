import CmuxNextCompat
import CmuxNextControl
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
struct DraftRootIsolationTests {
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
            for candidates in [appRoots, daemonRoots] {
                let selected = candidates.filter { $0.deletingLastPathComponent().lastPathComponent == "builds" }
                #expect(Set(selected.map(\.lastPathComponent)) == [build.key])
            }
        }
    }
}
