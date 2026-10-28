import CmuxNextCompat
import Darwin
public import Foundation
import MachO

/// Function names of the app executable, for symbolicating its frames in hang
/// records and exception traces.
///
/// The cmux NEXT Release executable links without exports
/// (`LD_EXPORT_SYMBOLS = NO`, `-no_exported_symbols`) and the release
/// strip removes its symbol table, so `dladdr` finds no names in it. Before
/// stripping, `scripts/write-app-symbol-map.py` writes them into
/// `Contents/Resources/cmux-symbols.bin`: per executable slice, its `LC_UUID`
/// and the `__TEXT,__text` functions as offsets from the image's Mach-O
/// header, ending with an unnamed entry at the end of `__TEXT,__text`.
/// Builds that skip the release strip (DEV) have no map and keep
/// their symbol table.
public struct AppSymbolMap: Sendable {
    /// Function start offsets from the image header, ascending.
    let offsets: [UInt]
    /// The names as `dladdr` gives them (mangled), joined by NUL, one per
    /// offset. Decoded only for a looked-up frame: a map holds ~450k names.
    let nameBytes: [UInt8]
    /// Where each name starts in ``nameBytes``, one per offset.
    let nameStarts: [UInt32]

    /// Reads the map of the running executable, or nil when the bundle has none
    /// or it holds no slice with this executable's UUID. A file read and an
    /// inflate: call it off the main thread, once per symbolication job (the
    /// hang recorder's symbol queue, a crash record), never from a static
    /// initializer that blocks whichever thread reads it first.
    public static func loadMain() -> AppSymbolMap? {
        guard let uuid = Self.executableImage()?.uuid,
              let url = Bundle.main.url(forResource: "cmux-symbols", withExtension: "bin"),
              let data = try? Data(blockingContentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return AppSymbolMap(data: data, uuid: uuid)
    }

    /// The slice for `uuid` in a `cmux-symbols.bin` file, or nil when there is
    /// none or the file does not decode.
    ///
    /// - Parameters:
    ///   - data: The file's bytes.
    ///   - uuid: The executable's `LC_UUID`.
    public init?(data: Data, uuid: UUID) {
        var file = Reader(bytes: [UInt8](data))
        guard file.take(8) == Array("CMXSYM1\0".utf8), let count = file.uint32() else { return nil }
        let wanted = Self.bytes(of: uuid)
        for _ in 0..<count {
            guard let slice = file.take(16), let size = file.uint32(),
                  let payload = file.take(Int(truncatingIfNeeded: size))
            else { return nil }
            guard slice == wanted else { continue }
            guard let inflated = try? (Data(payload) as NSData).decompressed(using: .zlib),
                  let table = Self.table(Reader(bytes: [UInt8](inflated as Data)))
            else { return nil }
            offsets = table.offsets
            nameBytes = table.nameBytes
            nameStarts = table.nameStarts
            return
        }
        return nil
    }

    /// The function holding `offset` (from the image header): its mangled
    /// name and the offset into it, or nil before the first function or past
    /// the end of `__TEXT,__text` (stubs).
    public func function(at offset: UInt) -> (name: String, offset: UInt)? {
        // The first function starting after `offset`; the one before it holds it.
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if let start = offsets[checked: middle], start <= offset { low = middle + 1 } else { high = middle }
        }
        guard let start = offsets[checked: low - 1], let name = name(at: low - 1) else { return nil }
        return (name, offset - start)
    }

    /// The name of entry `index`; nil for the unnamed end of `__TEXT,__text`.
    private func name(at index: Int) -> String? {
        guard let first = nameStarts[checked: index] else { return nil }
        let start = Int(truncatingIfNeeded: first)
        // A name ends at the NUL before the next name, the last at the end.
        let end = nameStarts[checked: index + 1].map { Int(truncatingIfNeeded: $0) - 1 } ?? nameBytes.count
        guard start >= 0, start < end, end <= nameBytes.count else { return nil }
        return String(decoding: nameBytes.dropFirst(start).prefix(end - start), as: UTF8.self)
    }

    /// The running executable's `LC_UUID` (nil when it has none) and load address, the address of its Mach-O
    /// header; nil when dyld lists no image.
    static func executableImage() -> (uuid: UUID?, loadAddress: UInt)? {
        // SAFETY: image 0 is the main executable, which dyld loads first and never unloads, so its header stays
        // mapped; imageUUID reads only inside its load commands (FunctionStarts' note).
        guard let header = unsafe _dyld_get_image_header(0) else { return nil }
        let uuid = unsafe FunctionStarts.imageUUID(header: UnsafeRawPointer(header))
        return (uuid, unsafe UInt(bitPattern: header))
    }

    /// A UUID's 16 bytes in order, read as values (no pointer).
    static func bytes(of uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// Decodes a slice payload: u32 count, LEB128 offset deltas, NUL-joined names.
    private static func table(_ payload: Reader) -> (offsets: [UInt], nameBytes: [UInt8], nameStarts: [UInt32])? {
        var payload = payload
        guard let count = payload.uint32() else { return nil }
        var offsets: [UInt] = []
        offsets.reserveCapacity(Int(truncatingIfNeeded: count))
        var offset: UInt = 0
        for _ in 0..<count {
            guard let delta = payload.leb128() else { return nil }
            offset = offset.addingReportingOverflow(delta).partialValue
            offsets.append(offset)
        }
        let nameBytes = Array(payload.rest)
        var nameStarts: [UInt32] = [0]
        nameStarts.reserveCapacity(offsets.count)
        for (index, byte) in nameBytes.enumerated() where byte == 0 {
            guard let start = UInt32(exactly: index + 1) else { return nil }
            nameStarts.append(start)
        }
        guard nameStarts.count == offsets.count else { return nil }
        return (offsets, nameBytes, nameStarts)
    }

    /// Reads little-endian fields from a byte array; a read past the end is nil.
    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        mutating func byte() -> UInt8? {
            guard let value = bytes[checked: position] else { return nil }
            position += 1
            return value
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count - position else { return nil }
            defer { position += count }
            return Array(bytes.dropFirst(position).prefix(count))
        }

        mutating func uint32() -> UInt32? {
            guard let raw = take(4) else { return nil }
            return raw.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(truncatingIfNeeded: $1) }
        }

        /// An unsigned LEB128 value; at most 10 bytes for 64 bits.
        mutating func leb128() -> UInt? {
            var value: UInt = 0
            for shift in stride(from: UInt(0), to: 70, by: 7) {
                guard let next = byte() else { return nil }
                value |= UInt(truncatingIfNeeded: next & 0x7F) << shift
                if next < 0x80 { return value }
            }
            return nil
        }

        var rest: ArraySlice<UInt8> { bytes.dropFirst(position) }
    }
}
