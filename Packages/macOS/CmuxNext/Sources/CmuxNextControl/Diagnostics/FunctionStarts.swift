import Darwin
import Foundation
import MachO

/// The function start offsets of one loaded image (its `LC_FUNCTION_STARTS`, which lists every
/// function, named or stripped), so ``StackSymbolicator`` can refuse a `dladdr` name that does
/// not hold the address.
///
/// `dladdr` names the nearest exported symbol at or before an address. In an image whose local
/// symbols are stripped (the Debug dylib's Swift functions are), that symbol can be tens of
/// kilobytes away: hang samples then read `swift_Concurrency_fatalError + 43120`, which looks like
/// a crash but is an unnamed function far past that symbol's end. A function that starts between
/// the symbol and the address proves the name wrong.
struct FunctionStarts: Sendable, Equatable {
    /// Function starts as offsets from the image's Mach-O header, ascending.
    let offsets: [UInt]

    init(offsets: [UInt]) {
        self.offsets = offsets
    }

    /// Whether a function starts after `symbolOffset` and at or before `addressOffset` (both from
    /// the image header): then the symbol's function ended before the address.
    func startsBetween(symbolOffset: UInt, addressOffset: UInt) -> Bool {
        guard addressOffset > symbolOffset else { return false }
        // The first start after the symbol.
        var low = 0, high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            guard let start = offsets[checked: middle] else { return false }
            if start <= symbolOffset { low = middle + 1 } else { high = middle }
        }
        guard let next = offsets[checked: low] else { return false }
        return next <= addressOffset
    }

    /// Decodes `LC_FUNCTION_STARTS` data: ULEB128 deltas, the first from `textOffset` (the
    /// `__TEXT` segment's offset from the header, 0 for a dylib), ended by a zero delta.
    static func decode(_ data: UnsafeRawBufferPointer, textOffset: UInt) -> FunctionStarts {
        var offsets: [UInt] = []
        var address = textOffset
        var delta: UInt = 0, shift: UInt = 0
        // Every byte is read once: the loop ends with the data.
        for byte in data {
            if shift < UInt(truncatingIfNeeded: UInt.bitWidth) { delta |= UInt(truncatingIfNeeded: byte & 0x7F) << shift }
            shift += 7
            guard byte & 0x80 == 0 else { continue }
            guard delta != 0 else { break }  // the zero delta ends the table
            address &+= delta
            offsets.append(address)
            delta = 0
            shift = 0
        }
        return FunctionStarts(offsets: offsets)
    }

    /// The `LC_UUID` of the loaded image at `header`, uppercase; nil when it has none.
    static func uuid(header: UnsafeRawPointer) -> String? {
        let mach = header.assumingMemoryBound(to: mach_header_64.self).pointee
        guard mach.magic == MH_MAGIC_64 else { return nil }
        var command = header.advanced(by: MemoryLayout<mach_header_64>.size)
        var remaining = UInt64(truncatingIfNeeded: mach.sizeofcmds)
        let loadSize = UInt64(truncatingIfNeeded: MemoryLayout<load_command>.size)
        for _ in 0..<mach.ncmds {
            guard remaining >= loadSize else { return nil }
            let load = command.loadUnaligned(as: load_command.self)
            let size = UInt64(truncatingIfNeeded: load.cmdsize)
            guard size >= loadSize, size <= remaining else { return nil }
            remaining -= size
            if load.cmd == LC_UUID, size >= UInt64(truncatingIfNeeded: MemoryLayout<uuid_command>.size) {
                return UUID(uuid: command.loadUnaligned(as: uuid_command.self).uuid).uuidString
            }
            command = command.advanced(by: Int(truncatingIfNeeded: load.cmdsize))
        }
        return nil
    }

    /// The function starts of the loaded image at `header`, read from its mapped `__LINKEDIT`;
    /// nil when it has none or its load commands do not fit.
    static func read(header: UnsafeRawPointer) -> FunctionStarts? {
        let mach = header.assumingMemoryBound(to: mach_header_64.self).pointee
        guard mach.magic == MH_MAGIC_64 else { return nil }
        var command = header.advanced(by: MemoryLayout<mach_header_64>.size)
        var remaining = UInt64(truncatingIfNeeded: mach.sizeofcmds)
        let loadSize = UInt64(truncatingIfNeeded: MemoryLayout<load_command>.size)
        var textVM: UInt64?
        var linkedit: segment_command_64?
        var starts: linkedit_data_command?
        for _ in 0..<mach.ncmds {
            guard remaining >= loadSize else { return nil }
            let load = command.loadUnaligned(as: load_command.self)
            let size = UInt64(truncatingIfNeeded: load.cmdsize)
            guard size >= loadSize, size <= remaining else { return nil }
            remaining -= size
            if load.cmd == LC_SEGMENT_64, size >= UInt64(truncatingIfNeeded: MemoryLayout<segment_command_64>.size) {
                var segment = command.loadUnaligned(as: segment_command_64.self)
                let name = withUnsafeBytes(of: &segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { textVM = segment.vmaddr }
                if name == "__LINKEDIT" { linkedit = segment }
            } else if load.cmd == LC_FUNCTION_STARTS, size >= UInt64(truncatingIfNeeded: MemoryLayout<linkedit_data_command>.size) {
                starts = command.loadUnaligned(as: linkedit_data_command.self)
            }
            command = command.advanced(by: Int(truncatingIfNeeded: load.cmdsize))
        }
        guard let textVM, let linkedit, let starts, starts.datasize > 0,
              UInt64(truncatingIfNeeded: starts.dataoff) >= linkedit.fileoff,
              UInt64(truncatingIfNeeded: starts.dataoff) + UInt64(truncatingIfNeeded: starts.datasize) <= linkedit.fileoff + linkedit.filesize else { return nil }
        // The header sits at __TEXT's vmaddr plus the slide; __LINKEDIT's file bytes are mapped at its vmaddr plus the slide.
        let headerAddress = UInt64(truncatingIfNeeded: UInt(bitPattern: header))
        let dataAddress = headerAddress &- textVM &+ linkedit.vmaddr &+ UInt64(truncatingIfNeeded: starts.dataoff) &- linkedit.fileoff
        guard let base = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: dataAddress)) else { return nil }
        return decode(UnsafeRawBufferPointer(start: base, count: Int(truncatingIfNeeded: starts.datasize)), textOffset: 0)
    }
}
