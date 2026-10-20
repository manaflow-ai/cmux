import Foundation
import Testing
@testable import CmuxNextChromiumRuntime

/// Which installed pack a launch uses, and what cleanup keeps.
struct ChromiumRuntimeStoreTests {
    let folder: TemporaryFolder
    let store: ChromiumRuntimeStore

    init() throws {
        folder = try TemporaryFolder()
        store = ChromiumRuntimeStore(root: folder.url.appending(path: "ChromiumRuntime"))
    }

    /// Installs a minimal pack for `pin` the way the installer does.
    @discardableResult
    func install(_ pin: ChromiumRuntimePin) throws -> ChromiumRuntimeInstallation {
        let staging = try store.makeStagingDirectory()
        try FileManager.default.createDirectory(
            at: staging.appending(path: "\(pin.wrapper)/Contents/Frameworks"), withIntermediateDirectories: true)
        return try store.activate(staging: staging, pin: pin)
    }

    func pin(key: String, shimABI: String = "abi-1", teamID: String? = "ABCDE12345") -> ChromiumRuntimePin {
        ChromiumRuntimePin(key: key, cef: "154", chromium: "154", shimABI: shimABI, sha256: String(repeating: "0", count: 64),
                           size: 1, url: URL(string: "https://example.com/p")!, teamID: teamID, wrapper: "cmux Chromium.app")
    }

    @Test func defaultRootIsPerBundleID() {
        let root = ChromiumRuntimeStore.defaultRoot(applicationSupport: URL(filePath: "/Users/x/Library/Application Support"),
                                                    bundleIdentifier: "com.cmuxterm.app.nightly")
        #expect(root.path == "/Users/x/Library/Application Support/com.cmuxterm.app.nightly/ChromiumRuntime")
    }

    @Test func nothingInstalledSelectsNone() {
        #expect(store.select(for: pin(key: "aaaaaaaaaaaaaaaa")) == .none)
        #expect(store.select(for: pin(key: "aaaaaaaaaaaaaaaa")).needsDownload)
    }

    @Test func thePinnedPackWins() throws {
        try install(pin(key: "bbbbbbbbbbbbbbbb"))
        let pinned = try install(pin(key: "aaaaaaaaaaaaaaaa"))
        let selection = store.select(for: pin(key: "aaaaaaaaaaaaaaaa"))
        #expect(selection == .exact(pinned))
        #expect(!selection.needsDownload)
        #expect(selection.installation?.frameworksDirectory.path.hasSuffix("aaaaaaaaaaaaaaaa/cmux Chromium.app/Contents/Frameworks") == true)
    }

    @Test func aCompatiblePackBridgesAnUpdate() throws {
        let previous = try install(pin(key: "bbbbbbbbbbbbbbbb"))
        let selection = store.select(for: pin(key: "aaaaaaaaaaaaaaaa"))
        #expect(selection == .compatible(previous))
        #expect(selection.needsDownload)
    }

    @Test func anotherShimABIOrTeamIsNotCompatible() throws {
        try install(pin(key: "bbbbbbbbbbbbbbbb", shimABI: "abi-0"))
        try install(pin(key: "cccccccccccccccc", teamID: "OTHERTEAM1"))
        #expect(store.select(for: pin(key: "aaaaaaaaaaaaaaaa")) == .none)
    }

    @Test func aFolderWithoutItsRecordIsNotInstalled() throws {
        let unfinished = store.root.appending(path: "aaaaaaaaaaaaaaaa/cmux Chromium.app/Contents/Frameworks")
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        #expect(store.installation(key: "aaaaaaaaaaaaaaaa") == nil)
        #expect(store.select(for: pin(key: "aaaaaaaaaaaaaaaa")) == .none)
        // Activating over it replaces the unfinished folder.
        try install(pin(key: "aaaaaaaaaaaaaaaa"))
        #expect(store.installation(key: "aaaaaaaaaaaaaaaa") != nil)
    }

    @Test func pruneKeepsOnlyTheNamedPacks() throws {
        try install(pin(key: "aaaaaaaaaaaaaaaa"))
        try install(pin(key: "bbbbbbbbbbbbbbbb"))
        try install(pin(key: "cccccccccccccccc"))
        _ = try store.makeStagingDirectory()
        let partial = store.partialFile(for: pin(key: "dddddddddddddddd"))
        let kept = store.partialFile(for: pin(key: "aaaaaaaaaaaaaaaa"))
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: partial)
        try Data("x".utf8).write(to: kept)
        store.prune(keeping: ["aaaaaaaaaaaaaaaa", "cccccccccccccccc"])
        #expect(store.installations().map(\.pin.key).sorted() == ["aaaaaaaaaaaaaaaa", "cccccccccccccccc"])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(!names.contains { $0.hasPrefix(".staging-") })
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}
