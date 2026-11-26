import Foundation
import Testing
@testable import CmuxUpdaterTestSupport
@testable import CmuxUpdater

@Suite struct LiveAppChannelSwitchTests {
    /// An unsigned bundle never passes the live inspector.
    @Test func liveInspectorRejectsUnsignedBundle() throws {
        let root = try TemporaryDirectory()
        let app = try root.makeApp(named: "Fake.app", bundleIdentifier: "com.cmuxterm.app.nightly")
        let report = try? SecurityAppSignatureInspector().inspect(appURL: app, teamIdentifier: "7WLXT3NR37")
        #expect(report?.satisfiesDeveloperIDRequirement != true)
    }

    @Test func replacesAnUnregisteredCopyOfTheSameApp() async throws {
        let harness = try SwitcherHarness()
        let stale = try harness.root.makeApp(named: "Applications/cmux NIGHTLY.app", bundleIdentifier: "com.cmuxterm.app.nightly", marker: "old")

        _ = try await harness.switcher().switchTo(.nightly) { _ in }

        let marker = try String(contentsOf: stale.appendingPathComponent("Contents/marker"), encoding: .utf8)
        #expect(marker == "volume")
    }

    /// The live zip opener extracts a `ditto --keepParent` zip (the DEV publisher's) beside it,
    /// app at the top, and removes the extracted copy on detach.
    @Test func liveZipOpenerExtractsAndRemoves() async throws {
        let root = try TemporaryDirectory()
        let app = try root.makeApp(named: "build/cmux NEXT DEV.app", bundleIdentifier: "com.cmuxterm.app.debug.next")
        let zip = root.url.appendingPathComponent("dev.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let opener = DittoZipArchiveOpener()
        let folder = try await opener.attach(zip)
        let fileSystem = FileManagerAppInstallFileSystem()
        #expect(fileSystem.contentsOfDirectory(at: folder).map(\.lastPathComponent) == ["cmux NEXT DEV.app"])
        #expect(fileSystem.bundleIdentifier(ofAppAt: folder.appendingPathComponent("cmux NEXT DEV.app")) == "com.cmuxterm.app.debug.next")
        await opener.detach(folder)
        #expect(!fileSystem.fileExists(at: folder))

        await #expect(throws: DittoZipArchiveOpener.ExtractError.self) {
            try await opener.attach(root.url.appendingPathComponent("missing.zip"))
        }
    }
}
