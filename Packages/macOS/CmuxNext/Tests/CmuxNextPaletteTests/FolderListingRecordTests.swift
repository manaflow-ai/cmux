@testable import CmuxNextPalette
import Darwin
import Foundation
import Testing

/// A `readdir` record is only `d_reclen` bytes long, not `sizeof(dirent)`
/// (1048 bytes): the last record of the buffer can end just before an
/// unmapped page. Reading the whole `dirent`, or its whole 1024-byte
/// `d_name`, then faults (the SIGBUS in `FolderListing.readNow` that the
/// file-pages live check hit while a path was typed in Open File...).
@Suite struct FolderListingRecordTests {
    /// Builds a short record at the very end of a readable page that a
    /// PROT_NONE page follows, and reads it.
    @Test func aRecordThatEndsAtAnUnmappedPageIsReadWithoutTouchingIt() throws {
        let page = Int(getpagesize())
        let raw = try #require(mmap(nil, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        #expect(raw != MAP_FAILED)
        defer { munmap(raw, 2 * page) }
        #expect(mprotect(raw + page, page, PROT_NONE) == 0)
        let name = Array("notes.md".utf8)
        let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
        // The record's length, rounded up to 4 like the kernel's: header,
        // name, terminator.
        let length = (nameOffset + name.count + 1 + 3) & ~3
        let start = raw + page - length
        memset(start, 0, length)
        let record = start.bindMemory(to: dirent.self, capacity: 1)
        start.storeBytes(of: UInt16(length), toByteOffset: MemoryLayout<dirent>.offset(of: \dirent.d_reclen)!, as: UInt16.self)
        start.storeBytes(of: UInt16(name.count), toByteOffset: MemoryLayout<dirent>.offset(of: \dirent.d_namlen)!, as: UInt16.self)
        start.storeBytes(of: UInt8(DT_REG), toByteOffset: MemoryLayout<dirent>.offset(of: \dirent.d_type)!, as: UInt8.self)
        for (index, byte) in name.enumerated() { start.storeBytes(of: byte, toByteOffset: nameOffset + index, as: UInt8.self) }
        let read = FolderListing.record(record)
        #expect(read.name == "notes.md")
        #expect(read.type == UInt8(DT_REG))
    }
}
