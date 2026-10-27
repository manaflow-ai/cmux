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
///
/// Memory safety (every `unsafe` below): `header` is the Mach-O header of an image dyld has loaded and never
/// unloads (the app executable and the dylibs its stacks run in), so its header, its load commands (the
/// `sizeofcmds` bytes after the header) and its mapped `__LINKEDIT` stay readable for the process's life. A read
/// stays inside `sizeofcmds`: each command is read only after `remaining` proves its `cmdsize` fits, and a typed
/// command only when its `cmdsize` holds that type. Reads are `loadUnaligned` copies, so no typed view outlives
/// a statement.
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
    static func decode(_ data: some Sequence<UInt8>, textOffset: UInt) -> FunctionStarts {
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
        // SAFETY: the caller's `header` contract is imageUUID's (the type's note).
        unsafe imageUUID(header: header)?.uuidString
    }

    /// The `LC_UUID` of the loaded image at `header`; nil when it has none or its load commands do not fit.
    static func imageUUID(header: UnsafeRawPointer) -> UUID? {
        // SAFETY: a loaded image's header (see the type's note); the magic check comes before any command read.
        let mach = unsafe header.loadUnaligned(as: mach_header_64.self)
        guard mach.magic == MH_MAGIC_64 else { return nil }
        // SAFETY: the first load command follows the header (see the type's note).
        var command = unsafe header.advanced(by: MemoryLayout<mach_header_64>.size)
        var remaining = UInt64(truncatingIfNeeded: mach.sizeofcmds)
        let loadSize = UInt64(truncatingIfNeeded: MemoryLayout<load_command>.size)
        for _ in 0..<mach.ncmds {
            guard remaining >= loadSize else { return nil }
            // SAFETY: remaining >= loadSize, so a load_command fits at `command` (see the type's note).
            let load = unsafe command.loadUnaligned(as: load_command.self)
            let size = UInt64(truncatingIfNeeded: load.cmdsize)
            guard size >= loadSize, size <= remaining else { return nil }
            remaining -= size
            if load.cmd == LC_UUID, size >= UInt64(truncatingIfNeeded: MemoryLayout<uuid_command>.size) {
                // SAFETY: the command's cmdsize holds a uuid_command and fits (checked above).
                return unsafe UUID(uuid: command.loadUnaligned(as: uuid_command.self).uuid)
            }
            // SAFETY: cmdsize <= the bytes left before this step, so the next command starts inside the commands
            // or at their end, where the loop's `remaining` guard stops before any read.
            unsafe command = command.advanced(by: Int(truncatingIfNeeded: load.cmdsize))
        }
        return nil
    }

    /// The function starts of the loaded image at `header`, read from its mapped `__LINKEDIT`;
    /// nil when it has none or its load commands do not fit.
    static func read(header: UnsafeRawPointer) -> FunctionStarts? {
        // SAFETY: a loaded image's header (see the type's note); the magic check comes before any command read.
        let mach = unsafe header.loadUnaligned(as: mach_header_64.self)
        guard mach.magic == MH_MAGIC_64 else { return nil }
        // SAFETY: the first load command follows the header (see the type's note).
        var command = unsafe header.advanced(by: MemoryLayout<mach_header_64>.size)
        var remaining = UInt64(truncatingIfNeeded: mach.sizeofcmds)
        let loadSize = UInt64(truncatingIfNeeded: MemoryLayout<load_command>.size)
        var textVM: UInt64?
        var linkedit: segment_command_64?
        var starts: linkedit_data_command?
        for _ in 0..<mach.ncmds {
            guard remaining >= loadSize else { return nil }
            // SAFETY: remaining >= loadSize, so a load_command fits at `command` (see the type's note).
            let load = unsafe command.loadUnaligned(as: load_command.self)
            let size = UInt64(truncatingIfNeeded: load.cmdsize)
            guard size >= loadSize, size <= remaining else { return nil }
            remaining -= size
            if load.cmd == LC_SEGMENT_64, size >= UInt64(truncatingIfNeeded: MemoryLayout<segment_command_64>.size) {
                // SAFETY: the command's cmdsize holds a segment_command_64 and fits (checked above).
                let segment = unsafe command.loadUnaligned(as: segment_command_64.self)
                let name = Self.segmentName(segment.segname)
                if name == "__TEXT" { textVM = segment.vmaddr }
                if name == "__LINKEDIT" { linkedit = segment }
            } else if load.cmd == LC_FUNCTION_STARTS, size >= UInt64(truncatingIfNeeded: MemoryLayout<linkedit_data_command>.size) {
                // SAFETY: the command's cmdsize holds a linkedit_data_command and fits (checked above).
                starts = unsafe command.loadUnaligned(as: linkedit_data_command.self)
            }
            // SAFETY: cmdsize <= the bytes left before this step, so the next command starts inside the commands
            // or at their end, where the loop's `remaining` guard stops before any read.
            unsafe command = command.advanced(by: Int(truncatingIfNeeded: load.cmdsize))
        }
        guard let textVM, let linkedit, let starts, starts.datasize > 0,
              UInt64(truncatingIfNeeded: starts.dataoff) >= linkedit.fileoff,
              UInt64(truncatingIfNeeded: starts.dataoff) + UInt64(truncatingIfNeeded: starts.datasize) <= linkedit.fileoff + linkedit.filesize else { return nil }
        // The header sits at __TEXT's vmaddr plus the slide; __LINKEDIT's file bytes are mapped at its vmaddr plus the slide.
        // SAFETY: reads only the header pointer's address, as an integer.
        let headerAddress = UInt64(truncatingIfNeeded: unsafe UInt(bitPattern: header))
        let dataAddress = headerAddress &- textVM &+ linkedit.vmaddr &+ UInt64(truncatingIfNeeded: starts.dataoff) &- linkedit.fileoff
        // SAFETY: the table's file range lies inside __LINKEDIT's (checked above), and __LINKEDIT's file bytes
        // are mapped at its vmaddr plus the image's slide, the header's address minus __TEXT's vmaddr; decode
        // reads each of its datasize bytes once, before this call returns.
        guard let base = unsafe UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: dataAddress)) else { return nil }
        return unsafe decode(UnsafeRawBufferPointer(start: base, count: Int(truncatingIfNeeded: starts.datasize)), textOffset: 0)
    }

    /// A segment's name: its 16 `segname` bytes up to the first NUL, read as values (no pointer).
    static func segmentName(_ name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                     CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
        let bytes = [name.0, name.1, name.2, name.3, name.4, name.5, name.6, name.7,
                     name.8, name.9, name.10, name.11, name.12, name.13, name.14, name.15]
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
