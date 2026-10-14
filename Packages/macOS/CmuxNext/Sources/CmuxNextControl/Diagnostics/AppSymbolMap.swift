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
/// header. Builds that skip the release strip (DEV) have no map and keep
/// their symbol table.
public struct AppSymbolMap: Sendable {
    /// Function start offsets from the image header, ascending.
    let offsets: [UInt]
    /// Mangled names, one per offset.
    let names: [String]

    /// The map of the running executable, or nil when the bundle has none or
    /// it holds no slice with this executable's UUID. Loaded on first use;
    /// read it off the main thread.
    // Immutable data read from the bundle once, not runtime state.
    public static let main: AppSymbolMap? = {
        guard let header = _dyld_get_image_header(0), let uuid = Self.uuid(of: header),
              let url = Bundle.main.url(forResource: "cmux-symbols", withExtension: "bin"),
              // concurrency-allow: diagnostics only, read once off the main thread.
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return AppSymbolMap(data: data, uuid: uuid)
    }()

    /// The slice for `uuid` in a `cmux-symbols.bin` file, or nil when there is
    /// none or the file does not decode.
    ///
    /// - Parameters:
    ///   - data: The file's bytes.
    ///   - uuid: The executable's `LC_UUID`.
    public init?(data: Data, uuid: UUID) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.starts(with: Array("CMXSYM1\0".utf8)) else { return nil }
        var position = 12
        for _ in 0..<Self.uint32(bytes, 8) {
            guard position + 20 <= bytes.count else { return nil }
            let slice = UUID(uuid: (bytes[position], bytes[position + 1], bytes[position + 2], bytes[position + 3],
                                    bytes[position + 4], bytes[position + 5], bytes[position + 6], bytes[position + 7],
                                    bytes[position + 8], bytes[position + 9], bytes[position + 10], bytes[position + 11],
                                    bytes[position + 12], bytes[position + 13], bytes[position + 14], bytes[position + 15]))
            let size = Int(Self.uint32(bytes, position + 16))
            let start = position + 20
            guard start + size <= bytes.count else { return nil }
            position = start + size
            guard slice == uuid else { continue }
            guard let payload = try? (Data(bytes[start..<start + size]) as NSData).decompressed(using: .zlib),
                  let table = Self.table([UInt8](payload as Data))
            else { return nil }
            offsets = table.offsets
            names = table.names
            return
        }
        return nil
    }

    /// The function holding `offset` (from the image header): its mangled
    /// name and the offset into it, or nil before the first function.
    public func function(at offset: UInt) -> (name: String, offset: UInt)? {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        return (names[low - 1], offset - offsets[low - 1])
    }

    /// The `LC_UUID` of the Mach-O image at `header`.
    static func uuid(of header: UnsafePointer<mach_header>) -> UUID? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_UUID {
                return UUID(uuid: command.load(as: uuid_command.self).uuid)
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    private static func uint32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// Decodes a slice payload: u32 count, LEB128 offset deltas, NUL-joined names.
    private static func table(_ payload: [UInt8]) -> (offsets: [UInt], names: [String])? {
        guard payload.count >= 4 else { return nil }
        let count = Int(uint32(payload, 0))
        var offsets: [UInt] = []
        offsets.reserveCapacity(count)
        var cursor = 4
        var offset: UInt = 0
        for _ in 0..<count {
            var delta: UInt = 0
            var ended = false
            // An unsigned LEB128 value of 64 bits takes at most 10 bytes.
            for shift in stride(from: UInt(0), to: 70, by: 7) {
                guard cursor < payload.count else { return nil }
                let byte = payload[cursor]
                cursor += 1
                delta |= UInt(byte & 0x7F) << shift
                if byte < 0x80 {
                    ended = true
                    break
                }
            }
            guard ended else { return nil }
            offset += delta
            offsets.append(offset)
        }
        let names = payload[cursor...].split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard names.count == count else { return nil }
        return (offsets, names)
    }
}
