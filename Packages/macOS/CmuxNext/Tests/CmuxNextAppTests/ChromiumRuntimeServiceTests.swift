@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextChromiumRuntime
import Foundation
import Testing

/// Chromium on demand in the app (plans/cmux-next/bundle-size-DESIGN.md
/// section 6.4): which runtime a launch uses, how download states reach the
/// engine, and what a person sees while Chromium is missing.
@MainActor struct ChromiumRuntimeServiceTests {
    let root: URL
    let store: ChromiumRuntimeStore
    let app = URL(filePath: "/Applications/cmux TEST.app")

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "chromium-runtime-service-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ChromiumRuntimeStore(root: root.appending(path: "ChromiumRuntime"))
    }

    func pin(_ key: String) -> ChromiumRuntimePin {
        ChromiumRuntimePin(key: key, cef: "154.0.28", chromium: "154.0.8037.58", shimABI: "abi-1", sha256: String(repeating: "0", count: 64),
                           size: 1, url: URL(string: "https://files.example.com/cef-runtime/\(key)/pack.tar.xz")!, teamID: "ABCDE12345",
                           folder: "cmux TEST Chromium")
    }

    /// Installs a pack with the runtime layout (framework, shim, base helper) the way the installer does.
    @discardableResult
    func install(_ pin: ChromiumRuntimePin) throws -> ChromiumRuntimeInstallation {
        let staging = try store.makeStagingDirectory()
        let frameworks = staging.appending(path: pin.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frameworks.appending(path: CEFRuntimeLayout.frameworkName), withIntermediateDirectories: true)
        try Data("shim".utf8).write(to: frameworks.appending(path: CEFRuntimeLayout.shimName))
        try FileManager.default.createDirectory(at: frameworks.appending(path: "cmux TEST Helper.app"), withIntermediateDirectories: true)
        return try store.activate(staging: staging, pin: pin)
    }

    func launch(_ pin: ChromiumRuntimePin) -> (service: ChromiumRuntimeService, inUse: Set<String>) {
        var inUse: Set<String> = []
        let service = ChromiumRuntimeService.launch(pin: pin, store: store, mainBundle: app) { keys in
            inUse = keys
            return ChromiumRuntimeInstaller(pin: pin, store: store, downloader: OfflineDownloader(), unpacker: OfflineDownloader(),
                                            signatures: OfflineDownloader(), network: OfflineDownloader(), maxAttempts: 1, keepAlso: { keys })
        }
        return (service, inUse)
    }

    @Test func aFirstLaunchHasNoRuntimeAndWaitsForTheDownload() {
        let (service, inUse) = launch(pin("aaaaaaaaaaaaaaaa"))
        #expect(service.origin == .downloading)
        #expect(service.source.layout == nil)
        #expect(service.source.unavailableReason == .downloading(fraction: nil))
        #expect(service.pinnedKey == "aaaaaaaaaaaaaaaa")
        #expect(inUse.isEmpty)
    }

    @Test func theInstalledPinnedPackRunsAtLaunch() throws {
        let installation = try install(pin("aaaaaaaaaaaaaaaa"))
        let (service, inUse) = launch(pin("aaaaaaaaaaaaaaaa"))
        #expect(service.origin == .installed)
        #expect(service.source.layout?.frameworksDirectory.path == installation.frameworksDirectory.path)
        // A flat pack is not an app: the app stays Chromium's main bundle (the helper sandbox reads only the pack folder).
        #expect(service.source.layout?.mainBundle.path == app.path)
        #expect(service.source.layout?.trust == .downloaded(teamID: "ABCDE12345"))
        #expect(inUse == ["aaaaaaaaaaaaaaaa"])
    }

    @Test func anOlderCompatiblePackRunsWhileTheUpdateDownloads() throws {
        let previous = try install(pin("bbbbbbbbbbbbbbbb"))
        let (service, inUse) = launch(pin("aaaaaaaaaaaaaaaa"))
        #expect(service.origin == .compatible)
        #expect(service.source.layout?.frameworksDirectory.path == previous.frameworksDirectory.path)
        // The cleanup after the new pack installs keeps the one this process runs.
        #expect(inUse == ["bbbbbbbbbbbbbbbb"])
    }

    @Test func downloadStatesReachTheEngineAndTheInstallSwitchesItToChromium() throws {
        let (service, _) = launch(pin("aaaaaaaaaaaaaaaa"))
        let engine = CEFEngine(source: service.source, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks())
        service.apply(.waitingForNetwork)
        #expect(engine.unavailableReason == .downloading(fraction: nil))
        service.apply(.downloading(received: 25, total: 100))
        #expect(engine.unavailableReason == .downloading(fraction: 0.25))
        service.apply(.failed(.http(503), attempt: 2))
        #expect(engine.unavailableReason == .downloadFailed("http: HTTP 503"))
        service.apply(.installed(try install(pin("aaaaaaaaaaaaaaaa"))))
        #expect(engine.runtimeSource.layout != nil)
        #expect(engine.unavailableReason == nil)
        #expect(service.state.name == "installed")
    }

    @Test func anInstallWithoutTheRuntimeLayoutStaysAFailure() throws {
        let (service, _) = launch(pin("aaaaaaaaaaaaaaaa"))
        let staging = try store.makeStagingDirectory()
        try FileManager.default.createDirectory(at: staging.appending(path: "cmux TEST Chromium"), withIntermediateDirectories: true)
        service.apply(.installed(try store.activate(staging: staging, pin: pin("aaaaaaaaaaaaaaaa"))))
        #expect(service.source.layout == nil)
        #expect(service.source.unavailableReason?.code == "downloadFailed")
    }

    @Test func aWebKitFallbackSaysWhyChromiumIsMissing() {
        #expect(ChromiumFallbackLog.notice(for: .downloading(fraction: 0.5)) == BrowserEngineStrings.fallbackDownloading)
        #expect(ChromiumFallbackLog.notice(for: .downloadFailed("http: HTTP 503")) == BrowserEngineStrings.fallbackDownloadFailed)
        #expect(ChromiumFallbackLog.notice(for: .notBundled) == BrowserEngineStrings.fallbackNotBundled)
    }

    @Test func anExplicitChromiumRequestShowsTheDownloadNotItsInternals() {
        #expect(BrowserTabService.message(.downloading(fraction: 0.42)).contains("42"))
        #expect(BrowserTabService.message(.downloadFailed("transfer: connection reset")) == BrowserEngineStrings.downloadFailed)
        #expect(BrowserTabService.message(.startFailed("dlopen failed")) == "dlopen failed")
    }
}

/// No network and nothing to unpack: these tests never download.
private struct OfflineDownloader: ChromiumRuntimeDownloading, ChromiumRuntimeUnpacking, ChromiumRuntimeSignatureChecking, ChromiumRuntimeNetwork {
    func download(_ url: URL, to file: URL, expectedSize: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws(ChromiumRuntimeInstallError) {
        throw .transfer("offline")
    }
    func entries(of archive: URL) async throws(ChromiumRuntimeInstallError) -> [String] { throw .unpack("offline") }
    func unpack(_ archive: URL, into directory: URL) async throws(ChromiumRuntimeInstallError) { throw .unpack("offline") }
    func check(_ item: URL, teamID: String) async throws(ChromiumRuntimeInstallError) { throw .signature("offline") }
    func isUsable(allowsExpensive: Bool) async -> Bool { false }
    func waitUntilUsable(allowsExpensive: Bool) async throws { throw CancellationError() }
}
