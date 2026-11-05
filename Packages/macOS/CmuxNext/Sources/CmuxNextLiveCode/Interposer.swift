// The Mach-O side of live code (LiveCode.swift): a patch's functions, matched by name to the app
// executable's and repointed there. A copy of the view shell's
// (Prototypes/ViewShell/Sources/ViewShell/LiveCode.swift), where it is proven; the two move to one
// shared module once the app's proof holds.
import Darwin
import Foundation
import MachO

enum LiveCodeError: Error, CustomStringConvertible {
    case open(String)
    case noImage
    case noInterposer
    case nothingToReplace
    case layoutChanged([String])

    var description: String {
        switch self {
        case .open(let message): "dlopen failed: \(message)"
        case .noImage: "the patch is loaded but dyld does not list it"
        case .noInterposer: "dyld_dynamic_interpose is not available"
        case .nothingToReplace: "the patch defines no function this build has (built against another build?)"
        case .layoutChanged(let types): "stored properties changed, rebuild instead: \(types.joined(separator: ", "))"
        }
    }
}

/// The Mach-O side: the patch's code symbols, matched by name to this executable's.
enum Interposer {
    private struct Tuple {
        var replacement: UnsafeRawPointer
        var replacee: UnsafeRawPointer
    }

    private typealias DynamicInterpose = @convention(c) (UnsafePointer<mach_header>, UnsafeRawPointer, Int) -> Void

    /// Loads the patch, off the main thread: dlopen holds dyld's loader lock while it maps and binds.
    /// Returns its handle's bit pattern, which ``apply(handle:dylib:)`` takes on the main actor.
    nonisolated static func load(_ path: String) throws -> Int {
        // concurrency-allow: called only from LiveCode.apply's detached task, never on the main thread
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LiveCodeError.open(String(cString: dlerror()))
        }
        return Int(bitPattern: handle)
    }

    /// One applied patch: each function it replaced, with its new code and the code it replaced
    /// (the executable's, or an earlier patch's). Rollback repoints `after` back to `before`.
    struct Applied {
        var after: [String: UnsafeRawPointer]
        var before: [String: UnsafeRawPointer]
    }

    @MainActor
    /// `current` holds each replaced function's newest code: dyld repoints the bindings that hold the
    /// replacee, which after the first patch is that patch's copy, not the executable's.
    static func apply(handle bits: Int, dylib path: String, current: inout [String: UnsafeRawPointer]) throws -> Applied {
        guard let handle = UnsafeMutableRawPointer(bitPattern: bits) else { throw LiveCodeError.open("no handle") }
        guard let index = (0..<_dyld_image_count()).last(where: { String(cString: _dyld_get_image_name($0)) == path
            || URL(fileURLWithPath: String(cString: _dyld_get_image_name($0))).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }), let header = _dyld_get_image_header(index) else { throw LiveCodeError.noImage }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_dynamic_interpose") else {
            throw LiveCodeError.noInterposer
        }
        let interpose = unsafeBitCast(symbol, to: DynamicInterpose.self)
        let mainOnly = UnsafeMutableRawPointer(bitPattern: -5) // RTLD_MAIN_ONLY
        let slide = _dyld_get_image_vmaddr_slide(index)
        let changed = layoutChanges(header: header, slide: slide, patch: handle, mainOnly: mainOnly)
        // A refused patch stays loaded (no dlclose); nothing points at it, and the next patch has a new name.
        guard changed.isEmpty else { throw LiveCodeError.layoutChanged(changed) }
        var tuples: [Tuple] = []
        var replaced: [String: UnsafeRawPointer] = [:]
        var before: [String: UnsafeRawPointer] = [:]
        for (name, address) in codeSymbols(header: header, slide: slide) {
            // Swift functions only, that the executable also defines.
            guard name.hasPrefix("_$s"), let old = dlsym(mainOnly, String(name.dropFirst())), UnsafeRawPointer(old) != address else { continue }
            let original = UnsafeRawPointer(old)
            tuples.append(Tuple(replacement: address, replacee: original))
            // An earlier patch's copy is what the bindings hold now: repoint that too.
            if let previous = current[name], previous != original, previous != address {
                tuples.append(Tuple(replacement: address, replacee: previous))
            }
            replaced[name] = address
            before[name] = current[name] ?? original
        }
        guard !tuples.isEmpty else { throw LiveCodeError.nothingToReplace }
        try repoint(tuples, to: replaced, interpose: interpose)
        current.merge(replaced) { $1 }
        return Applied(after: replaced, before: before)
    }

    /// Undoes `patch`, the newest applied: every function it replaced runs the code it replaced
    /// again. The patch's image stays loaded (no dlclose); nothing points at it.
    @MainActor
    static func revert(_ patch: Applied, current: inout [String: UnsafeRawPointer]) throws -> Int {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_dynamic_interpose") else {
            throw LiveCodeError.noInterposer
        }
        let tuples = patch.after.compactMap { name, now in patch.before[name].map { Tuple(replacement: $0, replacee: now) } }
        guard !tuples.isEmpty else { throw LiveCodeError.nothingToReplace }
        try repoint(tuples, to: patch.before, interpose: unsafeBitCast(symbol, to: DynamicInterpose.self))
        current.merge(patch.before) { $1 }
        return tuples.count
    }

    /// Hands `tuples` to dyld, then repoints the executable's already bound pointers to `targets`.
    @MainActor
    private static func repoint(_ tuples: [Tuple], to targets: [String: UnsafeRawPointer], interpose: DynamicInterpose) throws {
        guard let main = _dyld_get_image_header(0) else { throw LiveCodeError.noImage }
        tuples.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { interpose(main, base, tuples.count) }
        }
        // dyld_dynamic_interpose leaves a pointer that is already bound on the old code: a `body`
        // SwiftUI called before this patch kept drawing the build's view. Repoint those too.
        let rebound = rebind(header: main, slide: _dyld_get_image_vmaddr_slide(0), to: targets)
        if rebound.failed > 0 {
            // Those calls still reach the old code: say so rather than report a clean patch.
            FileHandle.standardError.write(Data("cmux live code: \(rebound.failed) symbol pointers stayed on the old code (mprotect failed)\n".utf8))
        }
    }

    /// Repoints the image's symbol pointers (`__la_symbol_ptr`, `__got`; the executable is linked
    /// with classic binds, `-no_fixup_chains`) that name a replaced function, as fishhook does.
    /// Its calls to its own Swift functions go through these (`-interposable`), and once dyld has
    /// bound one, `dyld_dynamic_interpose` does not rewrite it. Returns how many it wrote, and how
    /// many it could not (a page `mprotect` refused).
    @MainActor @discardableResult
    static func rebind(header: UnsafePointer<mach_header>, slide: Int,
                       to replacements: [String: UnsafeRawPointer]) -> (written: Int, failed: Int) {
        let base = UnsafeRawPointer(header)
        var command = base + MemoryLayout<mach_header_64>.size
        var linkedit: segment_command_64?
        var symtab: symtab_command?
        var dysymtab: dysymtab_command?
        var pointerSections: [section_64] = []
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_SEGMENT_64 {
                let segment = command.load(as: segment_command_64.self)
                let segmentName = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if segmentName == "__LINKEDIT" { linkedit = segment }
                var section = command + MemoryLayout<segment_command_64>.size
                for _ in 0..<segment.nsects {
                    let value = section.load(as: section_64.self)
                    // S_NON_LAZY_SYMBOL_POINTERS (6) and S_LAZY_SYMBOL_POINTERS (7).
                    if value.flags & 0xff == 6 || value.flags & 0xff == 7 { pointerSections.append(value) }
                    section += MemoryLayout<section_64>.size
                }
            } else if load.cmd == LC_SYMTAB {
                symtab = command.load(as: symtab_command.self)
            } else if load.cmd == LC_DYSYMTAB {
                dysymtab = command.load(as: dysymtab_command.self)
            }
            command += Int(load.cmdsize)
        }
        guard let linkedit, let symtab, let dysymtab, !replacements.isEmpty,
              let linkeditBase = UnsafeRawPointer(bitPattern: slide + Int(linkedit.vmaddr) - Int(linkedit.fileoff)) else { return (0, 0) }
        let symbols = (linkeditBase + Int(symtab.symoff)).assumingMemoryBound(to: nlist_64.self)
        let strings = (linkeditBase + Int(symtab.stroff)).assumingMemoryBound(to: CChar.self)
        let indirect = (linkeditBase + Int(dysymtab.indirectsymoff)).assumingMemoryBound(to: UInt32.self)
        let page = Int(getpagesize())
        var written = 0, failed = 0
        for section in pointerSections {
            guard let slots = UnsafeMutablePointer<UnsafeRawPointer?>(bitPattern: slide + Int(section.addr)) else { continue }
            for slot in 0..<Int(section.size) / MemoryLayout<UnsafeRawPointer>.size {
                let index = indirect[Int(section.reserved1) + slot]
                // INDIRECT_SYMBOL_LOCAL and INDIRECT_SYMBOL_ABS name no symbol.
                guard index & 0xC000_0000 == 0,
                      let replacement = replacements[String(cString: strings + Int(symbols[Int(index)].n_un.n_strx))] else { continue }
                // `__got` is in `__DATA_CONST`, read-only once dyld has bound it.
                let start = Int(bitPattern: slots + slot) & ~(page - 1)
                guard mprotect(UnsafeMutableRawPointer(bitPattern: start), page, PROT_READ | PROT_WRITE) == 0 else {
                    failed += 1
                    continue
                }
                slots[slot] = replacement
                written += 1
            }
        }
        return (written, failed)
    }

    private typealias MetadataAccessor = @convention(c) (Int) -> UnsafeRawPointer?

    /// The types the patch defines with another size than this build's: a struct or enum whose
    /// value size or stride differs, or a class whose instance size differs (an added or removed
    /// stored property, or one retyped to another size; a reorder or a same-size retype is not seen).
    /// Each non-generic type the patch and this build both define (`$s…VN`, `…ON`, `…CN`) is read
    /// through its metadata accessor (`…Ma`, request 0: complete), so a layout the runtime fills in
    /// (a field of a resilient type, such as SwiftUI's `State` or Foundation's `Date`) is compared too.
    static func layoutChanges(header: UnsafePointer<mach_header>, slide: Int, patch: UnsafeMutableRawPointer,
                              mainOnly: UnsafeMutableRawPointer?) -> [String] {
        var changed: [String] = []
        for (name, _) in symbols(header: header, slide: slide, code: false) {
            let kind = name.suffix(2)
            guard name.hasPrefix("_$s"), kind == "VN" || kind == "ON" || kind == "CN" else { continue }
            let accessor = String(name.dropFirst().dropLast()) + "Ma"
            guard let ours = dlsym(mainOnly, accessor), let theirs = dlsym(patch, accessor), ours != theirs,
                  let old = unsafeBitCast(ours, to: MetadataAccessor.self)(0),
                  let new = unsafeBitCast(theirs, to: MetadataAccessor.self)(0) else { continue }
            if kind == "CN" {
                // Class metadata: the instance size is the UInt32 at offset 48 from the address point.
                if old.load(fromByteOffset: 48, as: UInt32.self) != new.load(fromByteOffset: 48, as: UInt32.self) {
                    changed.append(String(name.dropFirst()))
                }
            } else {
                // Value metadata: its value witness table is the word before the address point;
                // size and stride follow the table's eight functions.
                let layout = { (metadata: UnsafeRawPointer) -> [Int] in
                    guard let table = metadata.load(fromByteOffset: -8, as: UnsafeRawPointer?.self) else { return [] }
                    return [table.load(fromByteOffset: 64, as: Int.self), table.load(fromByteOffset: 72, as: Int.self)]
                }
                if layout(old) != layout(new) { changed.append(String(name.dropFirst())) }
            }
        }
        return changed
    }

    /// The external symbols defined in the image's `__TEXT,__text`: its functions, not its data.
    private static func codeSymbols(header: UnsafePointer<mach_header>, slide: Int) -> [(String, UnsafeRawPointer)] {
        symbols(header: header, slide: slide, code: true)
    }

    /// The image's external defined symbols: those in `__TEXT,__text` (`code`), or every other section's.
    private static func symbols(header: UnsafePointer<mach_header>, slide: Int, code: Bool) -> [(String, UnsafeRawPointer)] {
        let base = UnsafeRawPointer(header)
        var command = base + MemoryLayout<mach_header_64>.size
        var sectionIndex = 0
        var textSection = 0
        var linkedit: segment_command_64?
        var symtab: symtab_command?
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_SEGMENT_64 {
                let segment = command.load(as: segment_command_64.self)
                let segmentName = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if segmentName == "__LINKEDIT" { linkedit = segment }
                var section = command + MemoryLayout<segment_command_64>.size
                for _ in 0..<segment.nsects {
                    sectionIndex += 1
                    let value = section.load(as: section_64.self)
                    let sectionName = withUnsafeBytes(of: value.sectname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if segmentName == "__TEXT", sectionName == "__text" { textSection = sectionIndex }
                    section += MemoryLayout<section_64>.size
                }
            } else if load.cmd == LC_SYMTAB {
                symtab = command.load(as: symtab_command.self)
            }
            command += Int(load.cmdsize)
        }
        guard let linkedit, let symtab, textSection != 0,
              let linkeditBase = UnsafeRawPointer(bitPattern: slide + Int(linkedit.vmaddr) - Int(linkedit.fileoff)) else { return [] }
        let symbols = (linkeditBase + Int(symtab.symoff)).assumingMemoryBound(to: nlist_64.self)
        let strings = (linkeditBase + Int(symtab.stroff)).assumingMemoryBound(to: CChar.self)
        var out: [(String, UnsafeRawPointer)] = []
        for index in 0..<Int(symtab.nsyms) {
            let symbol = symbols[index]
            let type = symbol.n_type
            guard type & UInt8(N_STAB) == 0, type & UInt8(N_TYPE) == UInt8(N_SECT), type & UInt8(N_EXT) != 0,
                  (Int(symbol.n_sect) == textSection) == code, let address = UnsafeRawPointer(bitPattern: Int(symbol.n_value) + slide) else { continue }
            out.append((String(cString: strings + Int(symbol.n_un.n_strx)), address))
        }
        return out
    }
}
