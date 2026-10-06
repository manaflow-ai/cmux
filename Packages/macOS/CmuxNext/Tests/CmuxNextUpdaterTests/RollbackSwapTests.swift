import Foundation
import Testing
@testable import CmuxNextUpdater

/// The rollback swap keeps the running build, then the kept bundle takes
/// its place.
@Suite struct RollbackSwapTests {
    private func app(_ dir: URL, _ name: String, build: String) throws -> URL {
        let app = dir.appending(path: name)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.0-nightly.\(build)"],
                                                      format: .xml, options: 0)
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    private func build(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }

    @Test func theKeptBuildReplacesTheRunningOneWhichIsKept() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swap-\(UUID().uuidString)")
        let store = KeptVersionStore(root: dir.appending(path: "versions"), teamID: { _ in "TEAM" })
        let running = try app(dir.appending(path: "Applications"), "cmux NIGHTLY.app", build: "20")
        try store.keep(bundle: try app(dir.appending(path: "old"), "cmux NIGHTLY.app", build: "19"), build: "19", limit: 3)
        let target = try #require(store.list().first)

        let placed = try RollbackSwap.perform(current: running, currentBuild: "20", target: target, store: store, limit: 3)
        #expect(placed == running)
        #expect(build(of: running) == "19")
        #expect(store.list().map(\.build) == ["20"])
    }

    @Test func theRelaunchWaitsForTheExitEventThenOpens() {
        let command = RollbackSwap.relaunchCommand(pid: 42, app: URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app"))
        #expect(command == ["/bin/sh", "-c", "/usr/bin/caffeinate -w 42; /usr/bin/open \"$0\"", "/Applications/cmux NIGHTLY.app"])
    }
}
