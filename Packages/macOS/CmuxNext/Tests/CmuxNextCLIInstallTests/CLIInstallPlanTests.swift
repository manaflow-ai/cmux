@testable import CmuxNextCLIInstall
import Foundation
import Testing

/// Where Install and Replace put `cmux`, and what the launch offer says, from
/// the same checks as `CLIPathCheckTests`.
struct CLIInstallPlanTests {
    typealias Scratch = CLIPathCheckTests.Scratch

    @Test func aPlainInstallRepointsADanglingLinkInPlaceAndSaysWhatItLinkedTo() throws {
        let scratch = try Scratch()
        let gone = scratch.root.appendingPathComponent("Applications/Gone.app/Contents/Resources/bin/cmux").path
        try scratch.link(scratch.early, to: gone)
        let plan = CLIInstallPlan(name: .cmux, replacing: false, check: scratch.check())
        #expect(plan.destination == scratch.early.appendingPathComponent("cmux"))
        #expect(plan.repointedFrom == gone)
        #expect(plan.replaces)
        #expect(CLIInstallReport.launchOffer(scratch.check())?.button == .repoint)
    }

    @Test func classicEarlierOnPathIsLeftAloneUntilReplaceThenReplacedWhereItIs() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.classicCLI.path)
        let check = scratch.check()
        let plain = CLIInstallPlan(name: .cmux, replacing: false, check: check)
        #expect(plain.destination == CLIPathInstaller.Name.cmux.destination)
        #expect(!plain.replaces)
        let replace = CLIInstallPlan(name: .cmux, replacing: true, check: check)
        #expect(replace.destination == scratch.early.appendingPathComponent("cmux"))
        #expect(replace.replaces)
        let offer = try #require(CLIInstallReport.launchOffer(check))
        #expect(offer.replacing)
        guard case .offerOther(let entry, let bundle, true) = offer.report else {
            Issue.record("expected classic's offer, got \(offer.report)")
            return
        }
        #expect(entry == scratch.early.appendingPathComponent("cmux").path)
        #expect(bundle.hasSuffix("/cmux.app"))
        #expect(offer.report.message.contains("classic"))
    }

    @Test func cmuxNextAlwaysGoesBesideInUsrLocalBin() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.classicCLI.path)
        let plan = CLIInstallPlan(name: .cmuxNext, replacing: false, check: scratch.check())
        #expect(plan.destination == CLIPathInstaller.Name.cmuxNext.destination)
        #expect(plan.repointedFrom == nil)
    }

    @Test func noOfferWhenCmuxRunsThisAppOrABuildOfTheCLI() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.source.path)
        #expect(CLIInstallReport.launchOffer(scratch.check()) == nil)
        let built = try Scratch()
        let file = built.early.appendingPathComponent("cmux")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(CLIInstallReport.launchOffer(built.check()) == nil)
    }

    @Test func missingOffersInstallWithoutReplacing() throws {
        let offer = try #require(CLIInstallReport.launchOffer(try Scratch().check()))
        #expect(offer.button == .install)
        #expect(!offer.replacing)
    }

    @Test func anotherAppsBinFolderOnPathIsNeverReplacedOrOffered() throws {
        let scratch = try Scratch()
        let bin = scratch.classicCLI.deletingLastPathComponent()
        let check = CLIPathCheck(path: "\(bin.path):\(scratch.late.path)", source: scratch.source)
        #expect(check.status.isClassic)
        #expect(check.entryIsInsideApp)
        #expect(check.replaceDestination == check.installDestination)
        #expect(CLIInstallPlan(name: .cmux, replacing: true, check: check).destination != scratch.classicCLI)
        #expect(CLIInstallReport.launchOffer(check) == nil)
    }

    @Test func uninstallAlsoRemovesThisAppsLinkWhereItRuns() throws {
        let scratch = try Scratch()
        try scratch.link(scratch.early, to: scratch.source.path)
        #expect(scratch.check().uninstallDestinations == [CLIPathInstaller.Name.cmux.destination, scratch.early.appendingPathComponent("cmux")])
        let classic = try Scratch()
        try classic.link(classic.early, to: classic.classicCLI.path)
        #expect(classic.check().uninstallDestinations == [CLIPathInstaller.Name.cmux.destination])
    }

    @Test func aDanglingLinkInsideAnAppBundleIsNeverRepointed() throws {
        let scratch = try Scratch()
        let bin = scratch.root.appendingPathComponent("Applications/Broken.app/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try scratch.link(bin, to: scratch.root.appendingPathComponent("Applications/Gone.app/Contents/Resources/bin/cmux").path)
        let check = CLIPathCheck(path: bin.path, source: scratch.source)
        #expect(check.status == .missing)
        #expect(CLIInstallPlan(name: .cmux, replacing: false, check: check).destination == CLIPathInstaller.Name.cmux.destination)
    }

    @Test func aPathFolderThatLinksIntoAnAppBundleIsProtectedToo() throws {
        let scratch = try Scratch()
        let bin = scratch.root.appendingPathComponent("Applications/Other.app/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let alias = scratch.root.appendingPathComponent("home-bin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bin)
        try scratch.link(bin, to: scratch.root.appendingPathComponent("Applications/Gone.app/Contents/Resources/bin/cmux").path)
        let dangling = CLIPathCheck(path: alias.path, source: scratch.source)
        #expect(dangling.status == .missing)
        try FileManager.default.removeItem(at: bin.appendingPathComponent("cmux"))
        try scratch.link(bin, to: scratch.classicCLI.path)
        let live = CLIPathCheck(path: alias.path, source: scratch.source)
        #expect(live.entryIsInsideApp)
        #expect(live.replaceDestination == live.installDestination)
        #expect(CLIInstallReport.launchOffer(live) == nil)
    }

    @Test func theInstallerNeverWritesInsideAnAppWhateverTheExtensionsCase() async throws {
        let scratch = try Scratch()
        let bin = scratch.root.appendingPathComponent("Applications/Other.APP/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        #expect(CLIPathCheck.appBundle(containing: bin.path)?.hasSuffix("Other.APP") == true)
        let entry = bin.appendingPathComponent("cmux")
        let installer = CLIPathInstaller(destination: entry, source: scratch.source) { _ in Issue.record("no administrator prompt") }
        await #expect(throws: CLIPathInstaller.Failure.destinationInsideApp(path: entry.path)) { try await installer.install(replacing: true) }
        await #expect(throws: CLIPathInstaller.Failure.destinationInsideApp(path: entry.path)) { try await installer.uninstall() }
        #expect(!FileManager.default.fileExists(atPath: entry.path))
    }
}
