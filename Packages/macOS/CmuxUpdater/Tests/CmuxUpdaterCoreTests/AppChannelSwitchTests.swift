import Foundation
import Testing
@testable import CmuxUpdaterTestSupport
@testable import CmuxUpdaterCore

@Suite struct AppChannelSwitchTargetTests {
    @Test func releaseAppsOfferEachOther() {
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app") == .nightly)
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app.nightly") == .stable)
    }

    @Test func nextNightlyAndDevOfferEachOther() {
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app.nightly.cmux-next") == .dev)
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app.debug.next") == .nightlyNext)
    }

    @Test func nextDownloadsAreTheNextNightlyDMGAndTheDevZip() {
        // The feed's newest build, never a rolling asset that can trail it.
        #expect(AppChannelSwitchTarget.nightlyNext.downloadURL(architecture: .arm64)?.absoluteString
            == "https://cmux.com/api/download/next")
        #expect(AppChannelSwitchTarget.nightlyNext.archive == .diskImage)
        #expect(AppChannelSwitchTarget.dev.downloadURL(architecture: .arm64)?.absoluteString
            == "https://github.com/manaflow-ai/cmux/releases/download/cmux-next-dev/cmux-NEXT-DEV.zip")
        #expect(AppChannelSwitchTarget.dev.archive == .zip)
    }

    @Test func devAndUnknownBuildsOfferNothing() {
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: nil) == nil)
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app.debug.my-tag") == nil)
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app.rc") == nil)
    }

    @Test func nightlyDownloadIsThePerArchitectureNightlyDMG() {
        #expect(AppChannelSwitchTarget.nightly.downloadURL(architecture: .arm64)?.absoluteString
            == "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-arm64.dmg")
        #expect(AppChannelSwitchTarget.nightly.downloadURL(architecture: .x86_64)?.absoluteString
            == "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-x86_64.dmg")
        #expect(AppChannelSwitchTarget.nightly.downloadURL(architecture: .arm64)?.absoluteString
            == UpdateManualDownloadRecovery.nightlyDownloadURLString(for: .arm64))
    }

    /// The stable DMG comes from the same release as the stable Sparkle feed.
    @Test func stableDownloadSitsInTheStableFeedRelease() throws {
        let dmg = try #require(AppChannelSwitchTarget.stable.downloadURL(architecture: .arm64))
        let feed = try #require(URL(string: UpdateFeedResolver().fallbackFeedURL))
        #expect(dmg.deletingLastPathComponent() == feed.deletingLastPathComponent())
        #expect(dmg.lastPathComponent == "cmux-macos.dmg")
        #expect(dmg.absoluteString == UpdateManualDownloadRecovery.stableDownloadURLString)
        #expect(AppChannelSwitchTarget.stable.downloadURL(architecture: .x86_64) == dmg)
    }
}

@Suite struct AppSignatureVerifierTests {
    private let verifier = AppSignatureVerifier()
    private func report(
        bundle: String? = "com.cmuxterm.app.nightly",
        signing: String? = "com.cmuxterm.app.nightly",
        team: String? = "7WLXT3NR37",
        valid: Bool = true
    ) -> AppSignatureReport {
        AppSignatureReport(bundleIdentifier: bundle, signingIdentifier: signing, teamIdentifier: team, satisfiesDeveloperIDRequirement: valid)
    }

    @Test func acceptsDeveloperIDSignatureForTeamAndBundle() throws {
        try verifier.verify(report(), bundleIdentifier: "com.cmuxterm.app.nightly")
    }

    @Test func rejectsInvalidSignature() {
        #expect(throws: AppSignatureVerificationFailure.invalidSignature) {
            try verifier.verify(report(valid: false), bundleIdentifier: "com.cmuxterm.app.nightly")
        }
    }

    @Test func rejectsOtherTeam() {
        #expect(throws: AppSignatureVerificationFailure.unexpectedTeam("ABCDE12345")) {
            try verifier.verify(report(team: "ABCDE12345"), bundleIdentifier: "com.cmuxterm.app.nightly")
        }
        #expect(throws: AppSignatureVerificationFailure.unexpectedTeam(nil)) {
            try verifier.verify(report(team: nil), bundleIdentifier: "com.cmuxterm.app.nightly")
        }
    }

    @Test func rejectsOtherBundleInPlistOrSignature() {
        #expect(throws: AppSignatureVerificationFailure.unexpectedBundleIdentifier("com.cmuxterm.app")) {
            try verifier.verify(report(bundle: "com.cmuxterm.app"), bundleIdentifier: "com.cmuxterm.app.nightly")
        }
        #expect(throws: AppSignatureVerificationFailure.unexpectedBundleIdentifier("com.example.other")) {
            try verifier.verify(report(signing: "com.example.other"), bundleIdentifier: "com.cmuxterm.app.nightly")
        }
    }

    @Test func requirementPinsDeveloperIDAndTeam() {
        let requirement = AppSignatureVerifier.developerIDRequirement(teamIdentifier: "7WLXT3NR37")
        #expect(requirement.hasPrefix("anchor apple generic"))
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"7WLXT3NR37\""))
    }


}

@Suite struct AppChannelInstallLocationsTests {
    private let locations = AppChannelInstallLocations(
        systemApplicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
        userApplicationsDirectory: URL(fileURLWithPath: "/Users/me/Applications", isDirectory: true)
    )

    @Test func installsIntoSystemApplicationsWhenWritable() {
        let destination = locations.installDestination(appName: "cmux NIGHTLY.app") { _ in true }
        #expect(destination.path == "/Applications/cmux NIGHTLY.app")
    }

    @Test func fallsBackToUserApplicationsWhenSystemIsReadOnly() {
        let destination = locations.installDestination(appName: "cmux NIGHTLY.app") { $0.path != "/Applications" }
        #expect(destination.path == "/Users/me/Applications/cmux NIGHTLY.app")
    }

    @Test func prefersSystemThenUserApplicationsCopy() {
        let candidates = [
            URL(fileURLWithPath: "/Users/me/Downloads/cmux NIGHTLY.app"),
            URL(fileURLWithPath: "/Users/me/Applications/cmux NIGHTLY.app"),
            URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app"),
        ]
        #expect(locations.preferredInstalledApp(from: candidates) { _ in true }?.path == "/Applications/cmux NIGHTLY.app")
        #expect(locations.preferredInstalledApp(from: Array(candidates.prefix(2))) { _ in true }?.path
            == "/Users/me/Applications/cmux NIGHTLY.app")
        #expect(locations.preferredInstalledApp(from: Array(candidates.prefix(1))) { _ in true }?.path
            == "/Users/me/Downloads/cmux NIGHTLY.app")
    }

    @Test func ignoresDiskImagesTrashTranslocationNestedAndMissingCopies() {
        let candidates = [
            URL(fileURLWithPath: "/Volumes/cmux NIGHTLY/cmux NIGHTLY.app"),
            URL(fileURLWithPath: "/Users/me/.Trash/cmux NIGHTLY.app"),
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/cmux NIGHTLY.app"),
            URL(fileURLWithPath: "/Applications/Other.app/Contents/Resources/cmux NIGHTLY.app"),
            URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app"),
        ]
        #expect(locations.preferredInstalledApp(from: candidates) { _ in true }?.path == "/Applications/cmux NIGHTLY.app")
        #expect(locations.preferredInstalledApp(from: candidates) { $0.path != "/Applications/cmux NIGHTLY.app" } == nil)
    }
}

@Suite struct AppChannelSwitcherTests {
    @Test func opensInstalledAppWithoutDownloading() async throws {
        let harness = try SwitcherHarness()
        let installed = try harness.root.makeApp(named: "Applications/cmux NIGHTLY.app", bundleIdentifier: "com.cmuxterm.app.nightly")
        harness.locator.urls = [installed]

        let outcome = try await harness.switcher().switchTo(.nightly) { _ in }

        #expect(outcome == .openedInstalledApp(installed.standardizedFileURL))
        #expect(harness.launcher.opened == [installed.standardizedFileURL])
        #expect(harness.downloader.requested.isEmpty)
    }

    @Test func downloadsVerifiesInstallsAndLaunchesWhenMissing() async throws {
        let harness = try SwitcherHarness()
        let phases = PhaseRecorder()

        let outcome = try await harness.switcher(architecture: .x86_64).switchTo(.nightly) { phases.append($0) }

        let destination = harness.systemApplications.appendingPathComponent("cmux NIGHTLY.app", isDirectory: true)
        #expect(outcome == .installedAndOpened(destination))
        let nightlyDMG = try #require(AppChannelSwitchTarget.nightly.downloadURL(architecture: .x86_64))
        #expect(harness.downloader.requested == [nightlyDMG])
        #expect(FileManagerAppInstallFileSystem().bundleIdentifier(ofAppAt: destination) == "com.cmuxterm.app.nightly")
        #expect(harness.inspector.inspected.count == 1)
        #expect(harness.inspector.inspected.first?.lastPathComponent == "cmux NIGHTLY.app")
        #expect(harness.inspector.inspected.first?.deletingLastPathComponent() != harness.mounter.volume)
        #expect(harness.mounter.detached == [harness.mounter.volume])
        #expect(harness.launcher.opened == [destination])
        #expect(phases.values.first == .downloading(fractionCompleted: nil))
        #expect(phases.values.contains(.downloading(fractionCompleted: 1)))
        #expect(Array(phases.values.suffix(3)) == [.verifying, .installing, .launching])
        #expect(harness.leftoverStagingEntries().isEmpty)
    }

    /// cmux NEXT DEV ships a zip: it is opened by the zip opener, then verified and installed
    /// like a DMG's app.
    @Test func devDownloadsTheZipAndInstallsTheDevApp() async throws {
        let harness = try SwitcherHarness()

        let outcome = try await harness.switcher().switchTo(.dev) { _ in }

        let destination = harness.systemApplications.appendingPathComponent("cmux.app", isDirectory: true)
        #expect(outcome == .installedAndOpened(destination))
        let devZip = try #require(AppChannelSwitchTarget.dev.downloadURL())
        #expect(harness.downloader.requested == [devZip])
        #expect(harness.mounter.attached.map(\.lastPathComponent) == ["dev.zip"])
        #expect(FileManagerAppInstallFileSystem().bundleIdentifier(ofAppAt: destination) == "com.cmuxterm.app.debug.next")
        #expect(harness.launcher.opened == [destination])
        #expect(harness.leftoverStagingEntries().isEmpty)
    }

    @Test func installsIntoUserApplicationsWhenSystemIsReadOnly() async throws {
        let harness = try SwitcherHarness()
        harness.fileSystem.readOnly = [harness.systemApplications.path]

        let outcome = try await harness.switcher().switchTo(.stable) { _ in }

        let destination = harness.userApplications.appendingPathComponent("cmux.app", isDirectory: true)
        #expect(outcome == .installedAndOpened(destination))
        let stableDMG = try #require(AppChannelSwitchTarget.stable.downloadURL())
        #expect(harness.downloader.requested == [stableDMG])
    }

    @Test func refusesAppThatFailsVerification() async throws {
        let harness = try SwitcherHarness()
        harness.inspector.report = AppSignatureReport(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            signingIdentifier: "com.cmuxterm.app.nightly",
            teamIdentifier: "ABCDE12345",
            satisfiesDeveloperIDRequirement: true
        )

        await #expect(throws: AppChannelSwitchError.verificationFailed(.unexpectedTeam("ABCDE12345"))) {
            try await harness.switcher().switchTo(.nightly) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: harness.systemApplications.appendingPathComponent("cmux NIGHTLY.app").path))
        #expect(harness.mounter.detached == [harness.mounter.volume])
        #expect(harness.launcher.opened.isEmpty)
        #expect(harness.leftoverStagingEntries().isEmpty)
    }

    @Test func refusesDiskImageWithoutTargetApp() async throws {
        let harness = try SwitcherHarness()
        harness.mounter.appBundleIdentifier = "com.example.other"

        await #expect(throws: AppChannelSwitchError.appNotFoundInDiskImage) {
            try await harness.switcher().switchTo(.nightly) { _ in }
        }
        #expect(harness.mounter.detached == [harness.mounter.volume])
    }

    @Test func neverReplacesAnUnrelatedAppAtTheDestination() async throws {
        let harness = try SwitcherHarness()
        let squatter = try harness.root.makeApp(named: "Applications/cmux NIGHTLY.app", bundleIdentifier: "com.example.other")

        await #expect(throws: AppChannelSwitchError.destinationOccupied(squatter)) {
            try await harness.switcher().switchTo(.nightly) { _ in }
        }
        #expect(FileManagerAppInstallFileSystem().bundleIdentifier(ofAppAt: squatter) == "com.example.other")
    }

    @Test func downloadFailureIsReportedAndCleansUp() async throws {
        let harness = try SwitcherHarness()
        harness.downloader.failure = URLSessionAppChannelDownloader.HTTPStatusError(statusCode: 404)

        await #expect(throws: AppChannelSwitchError.self) {
            try await harness.switcher().switchTo(.nightly) { _ in }
        }
        #expect(harness.mounter.attached.isEmpty)
        #expect(harness.leftoverWorkDirectories().isEmpty)
    }

    @Test func cancellationStopsBeforeInstalling() async throws {
        let harness = try SwitcherHarness()
        harness.downloader.cancelsCallingTask = true
        let switcher = harness.switcher()

        let task = Task { try await switcher.switchTo(.nightly) { _ in } }
        harness.downloader.taskToCancel = { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(harness.mounter.attached.isEmpty)
        #expect(harness.launcher.opened.isEmpty)
        #expect(harness.leftoverWorkDirectories().isEmpty)
    }

    @Test func mountPointParsesFromHdiutilPlist() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["content-hint": "GUID_partition_scheme", "dev-entry": "/dev/disk9"],
                ["content-hint": "Apple_HFS", "mount-point": "/Volumes/cmux NIGHTLY"],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(DiskImageAttachment(plist: data).mountPoint?.path == "/Volumes/cmux NIGHTLY")
        #expect(DiskImageAttachment(plist: Data("nope".utf8)).mountPoint == nil)
    }

    @Test func deviceEntryIsTheWholeDisk() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["dev-entry": "/dev/disk9s1"],
                ["dev-entry": "/dev/disk9"],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(DiskImageAttachment(plist: data).deviceEntry == "/dev/disk9")
    }

    /// A download started from an already-cancelled task must end, not wait forever.
    @Test func liveDownloaderEndsWhenStartedCancelled() async throws {
        let root = try TemporaryDirectory()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await URLSessionAppChannelDownloader().download(
                from: URL(string: "https://127.0.0.1:9/never.dmg")!,
                to: root.url.appendingPathComponent("never.dmg")
            ) { _ in }
        }
        await #expect(throws: (any Error).self) { try await task.value }
    }
}
