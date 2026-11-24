@testable import CmuxNextCLIInstall
import Foundation
import Testing

/// Which `cmux` a shell runs, as air-blue showed it (2026-11-08): Homebrew's
/// /opt/homebrew/bin comes before /usr/local/bin, a link there into a NIGHTLY
/// that was moved away dangled with nothing saying so, and classic's link kept
/// `cmux` running classic.
struct CLIPathCheckTests {
    /// A scratch root with `opt/bin` and `usr/bin` as PATH folders, this app's
    /// bundle and classic's.
    final class Scratch {
        let root: URL
        let early: URL
        let late: URL
        let source: URL
        let classicCLI: URL
        let otherCopyCLI: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-path-check-\(UUID().uuidString)")
            early = root.appendingPathComponent("opt/bin")
            late = root.appendingPathComponent("usr/bin")
            for folder in [early, late] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            source = try Self.bundle(root.appendingPathComponent("Applications/cmux NIGHTLY.app"), id: "com.cmuxterm.app.nightly")
            classicCLI = try Self.bundle(root.appendingPathComponent("Applications/cmux.app"), id: CLIPathCheck.classicBundleID)
            otherCopyCLI = try Self.bundle(root.appendingPathComponent("Applications/cmux NIGHTLY 2.app"), id: "com.cmuxterm.app.nightly")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var path: String { "\(early.path):\(late.path)" }

        func check() -> CLIPathCheck { CLIPathCheck(path: path, source: source) }

        func link(_ folder: URL, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("cmux").path, withDestinationPath: target)
        }

        /// An app bundle with an executable CLI; returns the CLI.
        static func bundle(_ app: URL, id: String) throws -> URL {
            let contents = app.appendingPathComponent("Contents")
            let bin = contents.appendingPathComponent("Resources/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"],
                                                           format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            let cli = bin.appendingPathComponent("cmux")
            try Data("#!/bin/sh\n".utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
            return cli
        }
    }

    @Test func noCmuxOnPathIsMissingAndInstallsInTheFirstStandardFolder() throws {
        let scratch = try Scratch()
        let check = scratch.check()
        #expect(check.status == .missing)
        #expect(check.entry == nil)
        // Neither scratch folder is a standard one: /usr/local/bin, as before.
        #expect(check.installDestination == CLIPathInstaller.Name.cmux.destination)
        let homebrewOnly = CLIPathCheck(path: "/opt/homebrew/bin:/usr/bin", source: scratch.source)
        #expect(homebrewOnly.installDestination.path == "/opt/homebrew/bin/cmux")
    }

    @Test func thisAppsLinkFirstOnPathRunsThisApp() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.source.path)
        #expect(scratch.check().runsThisApp)
    }

    @Test func aLinkIntoADeletedAppIsDanglingAndIsRepointedInPlace() throws {
        let scratch = try Scratch()
        let gone = scratch.root.appendingPathComponent("Applications/Gone.app/Contents/Resources/bin/cmux").path
        try scratch.link(scratch.early, to: gone)
        let check = scratch.check()
        #expect(check.status == .dangling(target: gone))
        #expect(check.entry == scratch.early.appendingPathComponent("cmux"))
        #expect(check.installDestination == scratch.early.appendingPathComponent("cmux"))
        #expect(check.replaceDestination == scratch.early.appendingPathComponent("cmux"))
    }

    @Test func aBrokenLinkThatIsNotIntoAnAppIsSkippedLikeAShellSkipsIt() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.root.appendingPathComponent("nowhere/cmux").path)
        #expect(scratch.check().status == .missing)
    }

    @Test func aDanglingLinkBeforeAWorkingOneDoesNotHideIt() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.root.appendingPathComponent("Applications/Gone.app/Contents/Resources/bin/cmux").path)
        try scratch.link(scratch.late, to: scratch.source.path)
        #expect(scratch.check().runsThisApp)
    }

    @Test func classicsLinkEarlierOnPathIsNamedClassicAndReplacedWhereItIs() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.classicCLI.path)
        try scratch.link(scratch.late, to: scratch.source.path)
        let check = scratch.check()
        #expect(check.status.isClassic)
        #expect(!check.runsThisApp)
        #expect(check.entry == scratch.early.appendingPathComponent("cmux"))
        #expect(check.replaceDestination == scratch.early.appendingPathComponent("cmux"))
    }

    @Test func anotherCopyOfThisAppIsAnotherAppNotClassic() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.otherCopyCLI.path)
        guard case .otherApp(let bundle, let classic) = scratch.check().status else {
            Issue.record("expected otherApp, got \(scratch.check().status)")
            return
        }
        #expect(bundle.hasSuffix("cmux NIGHTLY 2.app"))
        #expect(!classic)
    }

    @Test func aRelativeLinkIntoADeletedAppIsDanglingToo() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: "../../Applications/Gone.app/Contents/Resources/bin/cmux")
        #expect(scratch.check().status == .dangling(target: "../../Applications/Gone.app/Contents/Resources/bin/cmux"))
    }

    @Test func anotherAppsCLIInsideItsBundleIsForeignNotACmuxApp() throws {
        let scratch = try Scratch()
        let other = try Scratch.bundle(scratch.root.appendingPathComponent("Applications/Other.app"), id: "com.example.other")
        try scratch.link(scratch.early, to: other.path)
        #expect(scratch.check().status == .foreign)
    }

    @Test func aCLIOutsideAnyAppIsForeign() throws {
        let scratch = try Scratch()
        let built = scratch.early.appendingPathComponent("cmux")
        try Data("#!/bin/sh\n".utf8).write(to: built)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: built.path)
        let check = scratch.check()
        #expect(check.status == .foreign)
        #expect(check.entry == built)
    }

    @Test func aNonExecutableFileIsSkipped() throws {
        let scratch = try Scratch()
        try Data("not a program".utf8).write(to: scratch.early.appendingPathComponent("cmux"))
        try scratch.link(scratch.late, to: scratch.source.path)
        #expect(scratch.check().runsThisApp)
    }

    @Test func relativeAndRepeatedPathFoldersAreIgnored() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.late, to: scratch.source.path)
        let check = CLIPathCheck(path: "bin::\(scratch.late.path):\(scratch.late.path)", source: scratch.source)
        #expect(check.runsThisApp)
    }

    @Test func appBundleIsTheOutermostAppFolderOnThePath() {
        #expect(CLIPathCheck.appBundle(containing: "/Applications/cmux.app/Contents/Resources/bin/cmux") == "/Applications/cmux.app")
        #expect(CLIPathCheck.appBundle(containing: "/usr/local/bin/cmux") == nil)
    }

    @Test func repointingADanglingLinkReplacesItWithThisAppsCLI() async throws {
        let scratch = try Scratch()
        let entry = scratch.early.appendingPathComponent("cmux")
        try scratch.link(scratch.early, to: scratch.root.appendingPathComponent("Applications/Gone.app/Contents/Resources/bin/cmux").path)
        let installer = CLIPathInstaller(destination: entry, source: scratch.source) { _ in Issue.record("no administrator prompt") }
        do {
            _ = try await installer.install(replacing: false)
            Issue.record("a plain install replaced the link")
        } catch CLIPathInstaller.Failure.occupied(let path, .link) {
            #expect(path == entry.path)
        }
        _ = try await installer.install(replacing: true)
        #expect(scratch.check().runsThisApp)
    }
}
