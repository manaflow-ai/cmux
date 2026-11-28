import Foundation
import Testing
@testable import CmuxUpdater

@Suite struct AppChannelSwitchTargetTests {
    @Test func releaseAppsOfferEachOther() {
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app") == .nightly)
        #expect(AppChannelSwitchTarget.counterpart(ofBundleIdentifier: "com.cmuxterm.app.nightly") == .stable)
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

    /// An unsigned bundle never passes the live inspector.
    @Test func liveInspectorRejectsUnsignedBundle() throws {
        let root = try TemporaryDirectory()
        let app = try root.makeApp(named: "Fake.app", bundleIdentifier: "com.cmuxterm.app.nightly")
        let report = try? SecurityAppSignatureInspector().inspect(appURL: app, teamIdentifier: "7WLXT3NR37")
        #expect(report?.satisfiesDeveloperIDRequirement != true)
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

    @Test func replacesAnUnregisteredCopyOfTheSameApp() async throws {
        let harness = try SwitcherHarness()
        let stale = try harness.root.makeApp(named: "Applications/cmux NIGHTLY.app", bundleIdentifier: "com.cmuxterm.app.nightly", marker: "old")

        _ = try await harness.switcher().switchTo(.nightly) { _ in }

        let marker = try String(contentsOf: stale.appendingPathComponent("Contents/marker"), encoding: .utf8)
        #expect(marker == "volume")
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
        #expect(HdiutilDiskImageMounter.mountPoint(fromAttachPlist: data)?.path == "/Volumes/cmux NIGHTLY")
        #expect(HdiutilDiskImageMounter.mountPoint(fromAttachPlist: Data("nope".utf8)) == nil)
    }

    @Test func deviceEntryIsTheWholeDisk() throws {
        let plist: [String: Any] = [
            "system-entities": [
                ["dev-entry": "/dev/disk9s1"],
                ["dev-entry": "/dev/disk9"],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(HdiutilDiskImageMounter.deviceEntry(fromAttachPlist: data) == "/dev/disk9")
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

// MARK: - Test doubles

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-app-switch-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeApp(named relativePath: String, bundleIdentifier: String, marker: String = "") throws -> URL {
        let app = url.appendingPathComponent(relativePath, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        return app
    }
}

final class SwitcherHarness: @unchecked Sendable {
    let root: TemporaryDirectory
    let systemApplications: URL
    let userApplications: URL
    let temporary: URL
    let locator = FakeLocator()
    let downloader = FakeDownloader()
    let mounter: FakeMounter
    let inspector = FakeInspector()
    let launcher = FakeLauncher()
    let fileSystem = FakeFileSystem()

    init() throws {
        root = try TemporaryDirectory()
        systemApplications = root.url.appendingPathComponent("Applications", isDirectory: true)
        userApplications = root.url.appendingPathComponent("home/Applications", isDirectory: true)
        temporary = root.url.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: systemApplications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        mounter = FakeMounter(volume: root.url.appendingPathComponent("volume", isDirectory: true), root: root)
    }

    func switcher(architecture: UpdateHostArchitecture = .arm64) -> AppChannelSwitcher {
        AppChannelSwitcher(
            locator: locator,
            downloader: downloader,
            mounter: mounter,
            inspector: inspector,
            launcher: launcher,
            fileSystem: fileSystem,
            locations: AppChannelInstallLocations(
                systemApplicationsDirectory: systemApplications,
                userApplicationsDirectory: userApplications
            ),
            architecture: architecture,
            temporaryDirectory: temporary
        )
    }

    func leftoverStagingEntries() -> [String] {
        [systemApplications, userApplications].flatMap {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).filter { $0.hasPrefix(".cmux-app-switch-") }
        }
    }

    func leftoverWorkDirectories() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

final class PhaseRecorder: @unchecked Sendable {
    private let phases = Locked<[AppChannelSwitchPhase]>([])
    func append(_ phase: AppChannelSwitchPhase) { phases.value.append(phase) }
    var values: [AppChannelSwitchPhase] { phases.value }
}

final class FakeLocator: InstalledAppLocating, @unchecked Sendable {
    private let stored = Locked<[URL]>([])
    var urls: [URL] {
        get { stored.value }
        set { stored.value = newValue }
    }
    func applicationURLs(bundleIdentifier: String) -> [URL] { urls }
}

final class FakeDownloader: AppChannelDownloading, @unchecked Sendable {
    private let state = Locked<(requested: [URL], failure: (any Error)?, cancels: Bool, cancel: (@Sendable () -> Void)?)>(([], nil, false, nil))
    var requested: [URL] { state.value.requested }
    var failure: (any Error)? {
        get { state.value.failure }
        set { state.value.failure = newValue }
    }
    var cancelsCallingTask: Bool {
        get { state.value.cancels }
        set { state.value.cancels = newValue }
    }
    var taskToCancel: (@Sendable () -> Void)? {
        get { state.value.cancel }
        set { state.value.cancel = newValue }
    }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        state.value.requested.append(url)
        if let failure { throw failure }
        if cancelsCallingTask {
            while taskToCancel == nil { await Task.yield() }
            taskToCancel?()
            throw URLError(.cancelled)
        }
        progress(0.5)
        try Data("dmg".utf8).write(to: destination)
        progress(1)
    }
}

final class FakeMounter: DiskImageMounting, @unchecked Sendable {
    let volume: URL
    private let root: TemporaryDirectory
    private let state = Locked<(attached: [URL], detached: [URL], bundle: String)>(([], [], ""))
    var attached: [URL] { state.value.attached }
    var detached: [URL] { state.value.detached }
    /// Bundle identifier of the app placed on the volume; empty means "match the image name".
    var appBundleIdentifier: String {
        get { state.value.bundle }
        set { state.value.bundle = newValue }
    }

    init(volume: URL, root: TemporaryDirectory) {
        self.volume = volume
        self.root = root
    }

    func attach(_ image: URL) async throws -> URL {
        state.value.attached.append(image)
        let target = AppChannelSwitchTarget(rawValue: image.deletingPathExtension().lastPathComponent) ?? .nightly
        let name = target == .nightly ? "cmux NIGHTLY.app" : "cmux.app"
        let bundle = appBundleIdentifier.isEmpty ? target.bundleIdentifier : appBundleIdentifier
        try root.makeApp(named: "volume/\(name)", bundleIdentifier: bundle, marker: "volume")
        try Data().write(to: volume.appendingPathComponent("README.txt"))
        return volume
    }

    func detach(_ mountPoint: URL) async {
        state.value.detached.append(mountPoint)
    }
}

final class FakeInspector: AppSignatureInspecting, @unchecked Sendable {
    private let state = Locked<(report: AppSignatureReport?, inspected: [URL])>((nil, []))
    var report: AppSignatureReport? {
        get { state.value.report }
        set { state.value.report = newValue }
    }
    var inspected: [URL] { state.value.inspected }

    func inspect(appURL: URL, teamIdentifier: String) throws -> AppSignatureReport {
        state.value.inspected.append(appURL)
        if let report { return report }
        let bundle = FileManagerAppInstallFileSystem().bundleIdentifier(ofAppAt: appURL)
        return AppSignatureReport(
            bundleIdentifier: bundle,
            signingIdentifier: bundle,
            teamIdentifier: teamIdentifier,
            satisfiesDeveloperIDRequirement: true
        )
    }
}

final class FakeLauncher: AppLaunching, @unchecked Sendable {
    private let state = Locked<[URL]>([])
    var opened: [URL] { state.value }
    func openApplication(at appURL: URL) async throws { state.value.append(appURL) }
}

final class FakeFileSystem: AppInstallFileSystem, @unchecked Sendable {
    private let live = FileManagerAppInstallFileSystem()
    private let state = Locked<Set<String>>([])
    var readOnly: Set<String> {
        get { state.value }
        set { state.value = newValue }
    }

    func fileExists(at url: URL) -> Bool { live.fileExists(at: url) }
    func isWritableDirectory(_ directory: URL) -> Bool {
        !readOnly.contains(directory.path) && live.isWritableDirectory(directory)
    }
    func createDirectory(at directory: URL) throws { try live.createDirectory(at: directory) }
    func copyItem(at source: URL, to destination: URL) throws { try live.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) throws { try live.moveItem(at: source, to: destination) }
    func replaceItem(at original: URL, with replacement: URL) throws { try live.replaceItem(at: original, with: replacement) }
    func removeItem(at url: URL) { live.removeItem(at: url) }
    func contentsOfDirectory(at directory: URL) -> [URL] { live.contentsOfDirectory(at: directory) }
    func bundleIdentifier(ofAppAt appURL: URL) -> String? { live.bundleIdentifier(ofAppAt: appURL) }
}
