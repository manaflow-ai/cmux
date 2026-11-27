@testable import CmuxNextCompat
import Foundation
import Testing

/// A language pack's Chromium `locale.pak` is copied to one stable folder outside the signed app
/// (CMUX-570), where Chromium reads it first on its next start.
struct ChromiumLocalePaksTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-paks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pak(_ bytes: [UInt8], catalog: String = "de", in root: URL, pack: String) throws -> URL {
        let folder = root.appending(path: "\(pack)/ChromiumLocales/\(catalog).lproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "locale.pak")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func copiesThePakToItsCatalogFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try pak([1, 2, 3], in: root, pack: "aaa")
        let target = root.appending(path: "out", directoryHint: .isDirectory)
        #expect(ChromiumLocalePaks.install(pak: source, into: target) == "de.lproj")
        #expect(try Data(contentsOf: target.appending(path: "de.lproj/locale.pak")) == Data([1, 2, 3]))
    }

    @Test func aNewerPackReplacesTheCopyAndLeavesNoStagingFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "out", directoryHint: .isDirectory)
        #expect(ChromiumLocalePaks.install(pak: try pak([1], in: root, pack: "aaa"), into: target) == "de.lproj")
        #expect(ChromiumLocalePaks.install(pak: try pak([9, 9], in: root, pack: "bbb"), into: target) == "de.lproj")
        #expect(try Data(contentsOf: target.appending(path: "de.lproj/locale.pak")) == Data([9, 9]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.appending(path: "de.lproj").path) == ["locale.pak"])
    }

    @Test func refusesAFileThatIsNotALocalePak() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = root.appending(path: "other.pak")
        try Data([1]).write(to: stray)
        #expect(ChromiumLocalePaks.install(pak: stray, into: root.appending(path: "out")) == nil)
        #expect(ChromiumLocalePaks.install(pak: root.appending(path: "missing/locale.pak"), into: root.appending(path: "out")) == nil)
    }
}
