@testable import CmuxNextBrowserImport
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// Import from Browser's Extensions: what the daemon's plan read sends and decodes, the pages the
/// extensions workspace opens, and the copy of an unpacked folder. Which extensions a profile lacks
/// is the cmux-browser-import crate's `extension_plan` tests.
@Suite struct ImportedExtensionsTests {
    private nonisolated static let storeID = String(repeating: "a", count: 32)
    private nonisolated static let unpackedID = String(repeating: "c", count: 32)

    private static func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func extensionsAreOfferedUnchecked() {
        #expect(ImportStepModel.offeredKinds.contains(.extensions))
        #expect(ImportStepModel.optInKinds.contains(.extensions))
    }

    @Test func thePlanReadSendsTheExtensionsAndDecodesItsReply() async throws {
        let sent = Sent()
        let (storeID, unpackedID) = (Self.storeID, Self.unpackedID)
        let reader = BrowserDataReader { data in
            await sent.keep(data)
            let reply: [String: Any] = ["ok": [
                "store": [["id": storeID, "name": "Store", "enabled": true, "fromWebStore": true]],
                "unpacked": [["extension": ["id": unpackedID, "name": "Mine", "enabled": true, "fromWebStore": false,
                                            "unpackedPath": "/Users/me/ext"],
                              "copy": "/copies/\(unpackedID)"]],
                "installed": 2,
            ]]
            return try JSONSerialization.data(withJSONObject: reply)
        }
        let extensions = [ImportedExtension(id: Self.storeID, name: "Store"),
                          ImportedExtension(id: Self.unpackedID, name: "Mine", fromWebStore: false, unpackedPath: "/Users/me/ext")]
        let plan = try await reader.extensionInstallPlan(extensions, profile: URL(fileURLWithPath: "/cmux/Profile-x"),
                                                         copyRoot: URL(fileURLWithPath: "/copies"))
        #expect(plan.store.map(\.id) == [Self.storeID])
        #expect(plan.unpacked.map(\.copy) == ["/copies/\(Self.unpackedID)"])
        #expect(plan.unpacked.first?.extension.unpackedPath == "/Users/me/ext")
        #expect(plan.installed == 2)
        let data = try #require(await sent.requests.first)
        let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["reader"] as? String == "chromium.extension_install_plan")
        #expect(request["profile"] as? String == "/cmux/Profile-x")
        #expect(request["copyRoot"] as? String == "/copies")
        let listed = try #require(request["extensions"] as? [[String: Any]])
        #expect(listed.map { $0["id"] as? String } == [Self.storeID, Self.unpackedID])
        #expect(listed[0]["unpackedPath"] == nil, "a store install sends no folder")
        #expect(listed[1]["unpackedPath"] as? String == "/Users/me/ext")
    }

    @Test func theWorkspaceOpensTheExtensionsPageThenEachStorePage() {
        let pages = ImportedExtensionsInstaller.pages([ImportedExtension(id: Self.storeID, name: "Store"),
                                                       ImportedExtension(id: "not-an-id", name: "Bad")])
        #expect(pages.map(\.url.absoluteString) == ["chrome://extensions/", "https://chromewebstore.google.com/detail/\(Self.storeID)"])
        #expect(pages.map(\.title) == [nil, "Store"])
        #expect(ImportedTabsWorkspace(name: "x", profileID: "p", tabs: pages, chromium: true).chromium)
        #expect(ImportedExtension(id: Self.unpackedID, name: "Mine", fromWebStore: false, unpackedPath: "/x").webStorePage == nil)
    }

    @Test func anUnpackedFolderIsCopiedAndAStaleCopyReplaced() throws {
        let root = try Self.temporary("imported-extensions")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: "js"), withIntermediateDirectories: true)
        try Data(#"{"name":"Mine","manifest_version":3}"#.utf8).write(to: source.appending(path: "manifest.json"))
        try Data("1".utf8).write(to: source.appending(path: "js/a.js"))
        let destination = root.appending(path: "copies/\(Self.unpackedID)")
        // A copy an earlier run left (an older version) is replaced, never merged into.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "stale.js"))

        #expect(ImportedExtensionsInstaller.copyFolder(from: source.path, to: destination.path))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "js/a.js").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "stale.js").path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "js/a.js").path), "the source stays")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(leftovers == [Self.unpackedID], "no staging folder is left behind")

        // A folder without a manifest (moved, deleted) is not copied.
        let empty = root.appending(path: "gone")
        #expect(!ImportedExtensionsInstaller.copyFolder(from: empty.path, to: root.appending(path: "copies/other").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "copies/other").path))
    }

    @Test func extensionCountsReachTheSummaryLine() {
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Default", displayName: "Chrome",
                                                           proposedProfileID: "default", targetProfileID: "default"),
                                kinds: [.extensions])
        batch.extensions = [ImportedExtension(id: Self.storeID, name: "Store")]
        #expect(ImportSummary(batches: [batch]).counts.extensions == 1)
    }
}

private actor Sent {
    private(set) var requests: [Data] = []
    func keep(_ data: Data) { requests.append(data) }
}
