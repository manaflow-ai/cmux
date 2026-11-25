import CmuxUpdaterCore
import Foundation

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

final class SwitcherHarness: Sendable {
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
            installedAppLocator: locator,
            downloader: downloader,
            mounter: mounter,
            zipOpener: mounter,
            inspector: inspector,
            launcher: launcher,
            fileSystem: fileSystem,
            locations: AppChannelInstallLocations(
                systemApplicationsDirectory: systemApplications,
                userApplicationsDirectory: userApplications
            ),
            verifier: AppSignatureVerifier(),
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

// crash-allow: only the lock holder can access storage; returned values are Sendable.
final class Locked<Value: Sendable>: @unchecked Sendable {
    // lint:allow lock - synchronous protocol callbacks and the test task share this state.
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &storage
        }
    }
}

final class PhaseRecorder: Sendable {
    private let phases = Locked<[AppChannelSwitchPhase]>([])
    func append(_ phase: AppChannelSwitchPhase) { phases.value.append(phase) }
    var values: [AppChannelSwitchPhase] { phases.value }
}

final class FakeLocator: InstalledAppLocating {
    private let stored = Locked<[URL]>([])
    var urls: [URL] {
        get { stored.value }
        set { stored.value = newValue }
    }
    func applicationURLs(bundleIdentifier: String) -> [URL] { urls }
}

final class FakeDownloader: AppChannelDownloading {
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

final class FakeMounter: DiskImageMounting {
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

final class FakeInspector: AppSignatureInspecting {
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

final class FakeLauncher: AppLaunching {
    private let state = Locked<[URL]>([])
    var opened: [URL] { state.value }
    func openApplication(at appURL: URL) async throws { state.value.append(appURL) }
}

final class FakeFileSystem: AppInstallFileSystem {
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
