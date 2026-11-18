import CmuxNextDesign
@testable import CmuxNextMacScreen
import Foundation
import Testing

/// Screen sharing and computer use ask for, and System Settings lists, one app (Lawrence,
/// 2026-11-17: "ensure screen sharing + computer use uses same app for permissions"): a release,
/// NIGHTLY or RC build carries `cmux-screen-sharing` inside `cmux Computer Use.app`, and every
/// permission line names that app, the one whose switch the person turns on.
@MainActor @Suite
struct MacScreenGrantHolderTests {
    private static func makeApp() throws -> (root: URL, app: URL, bundle: Bundle) {
        let root = FileManager.default.temporaryDirectory.appending(path: "mac-screen-holder-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = root.appending(path: "cmux TEST.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Library"), withIntermediateDirectories: true)
        return (root, app, try #require(Bundle(url: app)))
    }

    private static func addExecutable(_ name: String, to helper: URL) throws {
        let executable = helper.appending(path: "Contents/MacOS/\(name)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
    }

    /// The Computer Use helper that carries the executable is the helper, ahead of a separate
    /// Screen Sharing helper in the same build; System Settings lists it as "cmux Computer Use".
    @Test func theComputerUseHelperCarryingTheExecutableIsTheHelper() throws {
        let (root, app, bundle) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let computerUse = app.appending(path: "Contents/Library/cmux Computer Use.app", directoryHint: .isDirectory)
        try Self.addExecutable("cmux-cua", to: computerUse)
        try Self.addExecutable(MacScreenHelper.executableName, to: computerUse)
        try Self.addExecutable(MacScreenHelper.executableName, to: app.appending(path: "Contents/Library/cmux TEST Screen Sharing.app", directoryHint: .isDirectory))

        let found = try #require(MacScreenHelper.bundled(bundle))
        #expect(found.name == "cmux Computer Use")
        #expect(found.app.standardizedFileURL == computerUse.standardizedFileURL)
    }

    /// A DEV build's Computer Use helper (or an older build's) has no screen sharing executable:
    /// the separate Screen Sharing helper serves; with neither, there is no helper.
    @Test func aComputerUseHelperWithoutTheExecutableFallsBackToTheSeparateHelper() throws {
        let (root, app, bundle) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.addExecutable("cmux-cua", to: app.appending(path: "Contents/Library/cmux Computer Use.app", directoryHint: .isDirectory))
        #expect(MacScreenHelper.bundled(bundle) == nil)

        let separate = app.appending(path: "Contents/Library/cmux TEST Screen Sharing.app", directoryHint: .isDirectory)
        try Self.addExecutable(MacScreenHelper.executableName, to: separate)
        let found = try #require(MacScreenHelper.bundled(bundle))
        #expect(found.name == "cmux TEST Screen Sharing")
        #expect(found.app.standardizedFileURL == separate.standardizedFileURL)
    }

    /// The guide's permission steps name the app whose switch the person turns on.
    @Test(arguments: CmuxRemoteSharingSetup.Step.allCases.filter { $0 != .overview })
    func theGuideNamesTheGrantHolder(_ step: CmuxRemoteSharingSetup.Step) {
        let spec = CmuxRemoteSharingSetup.spec(step, holder: "cmux Computer Use")
        #expect(spec.lines.contains { $0.contains("cmux Computer Use") }, "\(spec.lines)")
        if step == .screen || step == .screenCheck {
            #expect(spec.lines.allSatisfy { $0.contains("cmux Computer Use") }, "\(spec.lines)")
        }
    }

    /// Without the helper the grants are this app's, so the guide names this app.
    @Test func withoutTheHelperTheGuideNamesThisApp() throws {
        let (root, app, _) = try Self.makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "cmux TEST", "CFBundleIdentifier": "com.cmuxterm.test"],
                                                       format: .xml, options: 0)
        try plist.write(to: app.appending(path: "Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))
        #expect(MacScreenGrantCopy.holder(nil, app: bundle) == "cmux TEST")
        #expect(MacScreenGrantCopy.holder("", app: bundle) == "cmux TEST")
        #expect(MacScreenGrantCopy.setupAllow(nil, app: bundle).contains("cmux TEST"))
        #expect(MacScreenGrantCopy.setupScreenBody(nil, app: bundle).contains("cmux TEST"))
        let main = MacScreenGrantCopy.holder(nil)
        #expect(CmuxRemoteSharingSetup.spec(.screen).lines.allSatisfy { $0.contains(main) })
    }

    /// The running guide reads the holder from the share host after its grant check.
    @Test func theRunningGuideNamesTheHostsHolder() async throws {
        var setup = CmuxRemoteSharingSetup(host: MacScreenHubHost(share: MacScreenShareHost()))
        setup.refresh = { (false, false) }
        setup.enable = {}
        setup.holder = { "cmux Computer Use" }
        var shown: [[String]] = []
        let shared = try await setup.proceed(after: "continue") { spec in
            shown.append(spec.lines)
            return "cancel"
        }
        #expect(!shared)
        #expect(shown.count == 1)
        #expect(shown.first?.allSatisfy { $0.contains("cmux Computer Use") } == true, "\(shown)")
    }

    /// The Screen Recording rows name the helper; without one they keep this app's own copy.
    @Test func theScreenRecordingRowsNameTheHelper() {
        #expect(MacScreenGrantCopy.screenRecordingDetail("cmux Computer Use").contains("cmux Computer Use"))
        #expect(MacScreenGrantCopy.screenRecordingNeeded("cmux Computer Use").contains("cmux Computer Use"))
        #expect(MacScreenGrantCopy.screenRecordingDetail(nil)
            == L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux."))
        #expect(MacScreenGrantCopy.screenRecordingNeeded(nil)
            == L.t("macScreen.home.screenRecordingNeeded", "Needed to send this screen. macOS may ask you to reopen cmux."))
    }
}
