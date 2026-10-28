public import Foundation
import CmuxNextCompat

/// The `LC_UUID`s of Mach-O files on disk: one for a thin file, one per slice of a universal one. The crash
/// forwarder compares a host-exe copy's crashed image with them to tag whether this app's own binaries made
/// the copy (``SystemCrashForwarder``). The headers are read, never the whole file.
///
/// ```swift
/// let images = MachOImageUUIDs(files: [bin.appending(path: "cmux-holder")])  // blocking reads
/// images.contains(report.mainImageUUID)
/// ```
public struct MachOImageUUIDs: Sendable, Equatable {
    /// Each image's 16 `LC_UUID` bytes.
    public let uuids: Set<[UInt8]>

    /// The slices' UUIDs of `files`; a file that is missing or not Mach-O adds none. Blocking file reads.
    public init(files: [URL]) {
        var uuids: Set<[UInt8]> = []
        for file in files {
            guard let handle = try? FileHandle.blockingForReading(from: file) else { continue }
            defer { try? handle.close() }
            let read: (UInt64, Int) -> [UInt8]? = { offset, count in
                guard (try? blockingCall(.fileIO, { try handle.seek(toOffset: offset) })) != nil,
                      let data = try? handle.blockingRead(upToCount: count) else { return nil }
                return [UInt8](data)
            }
            uuids.formUnion(Self.uuids(read: read))
        }
        self.uuids = uuids
    }

    /// UUIDs from their bytes.
    public init(uuids: Set<[UInt8]>) {
        self.uuids = uuids
    }

    /// Whether `uuid` (a report's `8-4-4-4-12` text) is one of these images.
    public func contains(_ uuid: String?) -> Bool {
        guard let bytes = uuid.flatMap(RustCrashArtifacts.uuidBytes) else { return false }
        return uuids.contains(bytes)
    }

    /// The most load-command bytes one slice is read for: far more than a real image's.
    static let maxLoadCommandBytes = 1 << 20
    /// The most slices a universal file is read for.
    static let maxSlices = 16

    /// The UUIDs of the Mach-O file whose bytes `read(offset, count)` returns (fewer than `count` at its end).
    /// A thin 64-bit file (`MH_MAGIC_64`) has one; a universal file (`FAT_MAGIC`, `FAT_MAGIC_64`, big-endian) one
    /// per 64-bit slice (mach-o/fat.h, mach-o/loader.h).
    static func uuids(read: (UInt64, Int) -> [UInt8]?) -> Set<[UInt8]> {
        guard let head = read(0, 8), head.count == 8 else { return [] }
        switch Self.bigEndian32(head, 0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let wide = head[3] == 0xBF
            let entryBytes = wide ? 32 : 20
            let count = min(Int(Self.bigEndian32(head, 4)), Self.maxSlices)
            guard count > 0, let table = read(8, count * entryBytes), table.count == count * entryBytes else { return [] }
            var uuids: Set<[UInt8]> = []
            for index in 0 ..< count {
                let entry = index * entryBytes
                let offset = wide ? Self.bigEndian64(table, entry + 8) : UInt64(Self.bigEndian32(table, entry + 8))
                if let uuid = Self.sliceUUID(at: offset, read: read) { uuids.insert(uuid) }
            }
            return uuids
        default:
            return Self.sliceUUID(at: 0, read: read).map { [$0] } ?? []
        }
    }

    /// The `LC_UUID` of the 64-bit little-endian image at `offset`; nil when there is none.
    private static func sliceUUID(at offset: UInt64, read: (UInt64, Int) -> [UInt8]?) -> [UInt8]? {
        let headerBytes = 32
        guard let header = read(offset, headerBytes), header.count == headerBytes,
              Self.littleEndian32(header, 0) == 0xFEED_FACF else { return nil }
        let commandCount = Int(Self.littleEndian32(header, 16))
        let commandBytes = Int(Self.littleEndian32(header, 20))
        guard commandBytes <= Self.maxLoadCommandBytes,
              let commands = read(offset + UInt64(headerBytes), commandBytes), commands.count == commandBytes else { return nil }
        var cursor = 0
        for _ in 0 ..< commandCount {
            guard cursor + 8 <= commands.count else { return nil }
            let command = Self.littleEndian32(commands, cursor)
            let size = Int(Self.littleEndian32(commands, cursor + 4))
            guard size >= 8, cursor + size <= commands.count else { return nil }
            // LC_UUID: cmd, cmdsize, then the 16 bytes.
            if command == 0x1B, size >= 24 { return Array(commands[cursor + 8 ..< cursor + 24]) }
            cursor += size
        }
        return nil
    }

    private static func littleEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
    }

    private static func bigEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[at + $1]) }
    }

    private static func bigEndian64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[at + $1]) }
    }
}
