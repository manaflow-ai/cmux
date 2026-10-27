import Foundation
import Testing
@testable import CmuxNextFiles

/// The `getattrlistbulk` lister against real items in a temp folder.
struct DirectoryListerTests {
    @Test func listsKindsSizesAndHiddenItems() async throws {
        let temp = try TempFolder()
        try temp.file("plain.txt", bytes: 42)
        try temp.file(".dotfile")
        try temp.folder("Sub")
        try temp.folder("Thing.app")
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"),
                                                   withDestinationURL: temp.url.appendingPathComponent("Sub"))
        var names: Set<String> = ["plain.txt", ".dotfile", "Sub", "Thing.app", "link"]
        #if canImport(Darwin)
        // Linux has no UF_HIDDEN flag: a dot name alone hides an item there.
        let flagged = try temp.file("flagged")
        #expect(chflags(flagged.path, UInt32(UF_HIDDEN)) == 0)
        names.insert("flagged")
        #endif

        let entries = try await DirectoryLister().list(temp.url)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == names)
        #expect(byName["plain.txt"]?.kind == .file)
        #expect(byName["plain.txt"]?.size == 42)
        #expect(byName["plain.txt"]?.isHidden == false)
        #expect(byName[".dotfile"]?.isHidden == true)
        #if canImport(Darwin)
        #expect(byName["flagged"]?.isHidden == true)
        #endif
        #expect(byName["Sub"]?.kind == .folder)
        #expect(byName["Sub"]?.size == 0)
        #expect(byName["Thing.app"]?.kind == .package)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName["plain.txt"]?.url.path == temp.url.appendingPathComponent("plain.txt").path)
        #expect(abs((byName["plain.txt"]?.modified.timeIntervalSinceNow ?? 999)) < 120)
    }

    @Test func singleEntryMatchesTheListingAndNilWhenGone() async throws {
        let temp = try TempFolder()
        let file = try temp.file("one.txt", bytes: 7)
        let entry = await DirectoryLister().entry(at: file)
        #expect(entry?.size == 7)
        #expect(entry?.kind == .file)
        try FileManager.default.removeItem(at: file)
        #expect(await DirectoryLister().entry(at: file) == nil)
    }

    @Test func unreadableFolderThrows() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        await #expect(throws: FileBrowserError.unreadable(missing, ENOENT)) { try await DirectoryLister().list(missing) }
        #expect(FileBrowserError.systemText(ENOENT) == "No such file or directory")
        #expect(FileBrowserError.posix(EACCES) == .failed("Permission denied"))
    }

    #if canImport(Darwin)
    /// The batch parser reads each record with bounds checks: a record whose length runs past the
    /// buffer ends the batch, and the records before it are kept as the kernel wrote them.
    @Test func aBatchStopsAtARecordThatRunsPastTheBuffer() {
        let whole = Self.record(name: "a.txt", type: VREG, size: 42) + Self.record(name: "Sub", type: VDIR, size: nil)
        let batch = whole + Self.record(name: "cut", type: VREG, size: 1).prefix(10)
        var entries: [FileEntry] = []
        var packages: [String: Bool] = [:]
        DirectoryLister.parseBatch(batch, count: 3, in: Self.folder, packages: &packages, into: &entries)
        #expect(entries.map(\.name) == ["a.txt", "Sub"])
        #expect(entries.first?.kind == .file)
        #expect(entries.first?.size == 42)
        #expect(entries.first?.modified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entries.last?.kind == .folder)
        #expect(entries.last?.size == 0)
    }

    /// A record whose name reference points outside the record is skipped; the next record still parses.
    @Test func aRecordWhoseNamePointsOutsideItIsSkipped() {
        let batch = Self.record(name: "bad", type: VREG, size: 1, nameOffset: 4_096) + Self.record(name: "good", type: VREG, size: 2)
            + Self.record(name: "worse", type: VREG, size: 3, nameOffset: -64)
        var entries: [FileEntry] = []
        var packages: [String: Bool] = [:]
        DirectoryLister.parseBatch(batch, count: 3, in: Self.folder, packages: &packages, into: &entries)
        #expect(entries.map(\.name) == ["good"])
        #expect(entries.first?.size == 2)
    }

    private static let folder = URL(fileURLWithPath: "/tmp/batch", isDirectory: true)

    /// One record as getattrlistbulk(2) lays it out for the lister's request: the length, the returned
    /// attribute set, the name reference, type, both times, flags, the data length for a file, then the name.
    private static func record(name: String, type: vtype, size: UInt64?, nameOffset: Int32? = nil) -> [UInt8] {
        func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            stride(from: 0, to: T.bitWidth, by: 8).map { UInt8(truncatingIfNeeded: value >> $0) }
        }
        let common = attrgroup_t(bitPattern: ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS)
        let file: attrgroup_t = size == nil ? 0 : attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH)
        var fields = bytes(UInt32(type.rawValue)) + bytes(Int64(1_700_000_000)) + bytes(Int64(0))
        fields += bytes(Int64(1_700_000_000)) + bytes(Int64(0)) + bytes(UInt32(0))
        if let size { fields += bytes(size) }
        let text = Array(name.utf8) + [0]
        // The name's offset counts from the reference itself (8 bytes) past the fixed fields.
        let reference = bytes(nameOffset ?? Int32(8 + fields.count)) + bytes(UInt32(text.count))
        var body = bytes(common) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(file) + bytes(UInt32(0))
        body += reference + fields + text
        while body.count % 4 != 0 { body.append(0) }
        return bytes(UInt32(body.count + 4)) + body
    }
    #endif

    @Test func listsTenThousandItems() async throws {
        let temp = try TempFolder()
        for index in 1...10_000 { FileManager.default.createFile(atPath: temp.url.appendingPathComponent("f\(index)").path, contents: nil) }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = try await clock.measure { count = try await DirectoryLister().list(temp.url).count }
        #expect(count == 10_000)
        // Finder's own `count items` takes 350-860 ms on this folder size (PARITY.md).
        #expect(elapsed < .milliseconds(500))
    }
}
