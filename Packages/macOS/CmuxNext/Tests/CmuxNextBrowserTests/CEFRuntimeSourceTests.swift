@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chromium on demand: the engine's runtime arrives while the app runs
/// (plans/cmux-next/bundle-size-DESIGN.md section 6.4).
@MainActor struct CEFRuntimeSourceTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "cef-runtime-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A flat runtime folder shaped like a downloaded pack.
    func pack(helper: Bool = true) throws -> URL {
        let frameworks = root.appending(path: "packs/0123456789abcdef/cmux TEST Chromium", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: frameworks.appending(path: CEFRuntimeLayout.frameworkName), withIntermediateDirectories: true)
        try Data("shim".utf8).write(to: frameworks.appending(path: CEFRuntimeLayout.shimName))
        try fileManager.createDirectory(at: frameworks.appending(path: "cmux TEST Helper (GPU).app"), withIntermediateDirectories: true)
        if helper { try fileManager.createDirectory(at: frameworks.appending(path: "cmux TEST Helper.app"), withIntermediateDirectories: true) }
        return frameworks
    }

    @Test func aBuildWithoutRuntimeOrPackIsNotBundled() {
        let source = CEFRuntimeSource(layout: nil)
        #expect(source.unavailableReason == .notBundled)
        #expect(source.unavailableReason?.isAwaitingDownload == false)
    }

    @Test func aPendingDownloadIsTheReasonUntilTheRuntimeIsInstalled() throws {
        let source = CEFRuntimeSource(layout: nil, pending: .downloading(fraction: nil))
        let engine = CEFEngine(source: source, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks())
        #expect(engine.unavailableReason == .downloading(fraction: nil))
        source.update(pending: .downloading(fraction: 0.4))
        #expect(engine.unavailableReason == .downloading(fraction: 0.4))
        #expect(engine.unavailableReason?.isAwaitingDownload == true)
        source.update(pending: .downloadFailed("http: HTTP 503"))
        #expect(engine.unavailableReason?.code == "downloadFailed")
        #expect(engine.unavailableReason?.detail == "http: HTTP 503")
        #expect(engine.unavailableReason?.isAwaitingDownload == true)

        let layout = try #require(CEFRuntimeLayout.at(try pack(), fallbackMainBundle: root))
        #expect(source.install(layout))
        #expect(engine.layout == layout)
        #expect(source.unavailableReason == nil)
        #expect(engine.availability == .available)
    }

    @Test func theFirstRuntimeStaysOnceSet() throws {
        let layout = try #require(CEFRuntimeLayout.at(try pack(), fallbackMainBundle: root))
        let other = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let source = CEFRuntimeSource(layout: layout, pending: .downloading(fraction: nil))
        #expect(source.unavailableReason == nil)
        #expect(!source.install(other))
        source.update(pending: .downloadFailed("x"))
        #expect(source.layout == layout)
        #expect(source.unavailableReason == nil)
    }

    @Test func aFlatPackKeepsTheAppAsTheMainBundle() throws {
        let frameworks = try pack()
        let layout = try #require(CEFRuntimeLayout.at(frameworks, fallbackMainBundle: URL(filePath: "/Applications/cmux.app")))
        #expect(layout.mainBundle.path == "/Applications/cmux.app")
        #expect(layout.frameworksDirectory.lastPathComponent == "cmux TEST Chromium")
        #expect(layout.helperApp.lastPathComponent == "cmux TEST Helper.app")
        #expect(layout.helperExecutable.path.hasSuffix("cmux TEST Helper.app/Contents/MacOS/cmux TEST Helper"))
    }

    @Test func aPackWithoutItsBaseHelperHasNoLayout() throws {
        #expect(CEFRuntimeLayout.at(try pack(helper: false), fallbackMainBundle: root) == nil)
    }
}
