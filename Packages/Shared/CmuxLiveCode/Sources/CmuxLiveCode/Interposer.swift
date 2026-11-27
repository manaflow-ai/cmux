// The Mach-O side of live code (LiveEngine.swift): a patch's functions, matched by name to the app
// executable's and repointed there. Proven first in the view shell
// (Prototypes/ViewShell/Sources/ViewShell/LiveCode.swift), then in the macOS app; the iPhone app in
// the iOS Simulator runs the same code (a simulator app is a macOS process).
// Shipped iPhone builds (Release, TestFlight, App Store) compile none of it: on iOS only a DEBUG
// build (Debug, or ios-sim.sh's Demo with DEBUG) has the engine, so a Release binary holds no
// loader, no interposer and no private dyld symbol name. The macOS app keeps it in every build.
#if canImport(MachO) && (os(macOS) || DEBUG)
import Darwin
import Foundation
import MachO

/// The Mach-O side: the patch's code symbols, matched by name to this executable's. Nonisolated:
/// LiveCode's engine actor calls it, off the main thread.
enum Interposer {
    private struct Tuple {
        var replacement: UnsafeRawPointer
        var replacee: UnsafeRawPointer
    }

    private typealias DynamicInterpose = @convention(c) (UnsafePointer<mach_header>, UnsafeRawPointer, Int) -> Void

    /// Loads the patch, off the main thread: dlopen holds dyld's loader lock while it maps and binds.
    /// Returns its handle's bit pattern, which ``apply(handle:dylib:current:)`` takes.
    static func load(_ path: String) throws -> Int {
        // concurrency-allow: called only from LiveEngine, an actor off the main thread
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

    /// `current` holds each replaced function's newest code: dyld repoints the bindings that hold the
    /// replacee, which after the first patch is that patch's copy, not the executable's.
    static func apply(handle bits: Int, dylib path: String, current: inout [String: UnsafeRawPointer]) throws -> Applied {
        guard let handle = UnsafeMutableRawPointer(bitPattern: bits) else { throw LiveCodeError.open("no handle") }
        guard let index = (0..<_dyld_image_count()).last(where: { String(cString: _dyld_get_image_name($0)) == path
            || URL(fileURLWithPath: String(cString: _dyld_get_image_name($0))).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }), let header = _dyld_get_image_header(index) else { throw LiveCodeError.noImage }
        let interpose = dynamicInterpose()
        let mainOnly = UnsafeMutableRawPointer(bitPattern: -5) // RTLD_MAIN_ONLY
        let slide = _dyld_get_image_vmaddr_slide(index)
        let changed = layoutChanges(header: header, slide: slide, patch: handle, mainOnly: mainOnly)
        // A refused patch stays loaded (no dlclose); nothing points at it, and the next patch has a new name.
        guard changed.isEmpty else { throw LiveCodeError.layoutChanged(changed) }
        let retyped = opaqueTypeChanges(header: header, slide: slide, mainOnly: mainOnly)
        guard retyped.isEmpty else { throw LiveCodeError.opaqueTypeChanged(retyped) }
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
    static func revert(_ patch: Applied, current: inout [String: UnsafeRawPointer]) throws -> Int {
        let tuples = patch.after.compactMap { name, now in patch.before[name].map { Tuple(replacement: $0, replacee: now) } }
        guard !tuples.isEmpty else { throw LiveCodeError.nothingToReplace }
        try repoint(tuples, to: patch.before, interpose: dynamicInterpose())
        current.merge(patch.before) { $1 }
        return tuples.count
    }

    /// dyld's `dyld_dynamic_interpose`, when this process's dyld has it. The iOS Simulator's dyld
    /// (dyld_sim) may not: there the rebind below alone repoints the executable's calls, which the
    /// live code build routes through its symbol pointers.
    private static func dynamicInterpose() -> DynamicInterpose? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_dynamic_interpose").map { unsafeBitCast($0, to: DynamicInterpose.self) }
    }

    /// Whether this process's dyld has `dyld_dynamic_interpose` (the engine logs it when it starts).
    static var hasDynamicInterpose: Bool { dynamicInterpose() != nil }

    /// Hands `tuples` to dyld, then repoints the executable's already bound pointers to `targets`.
    private static func repoint(_ tuples: [Tuple], to targets: [String: UnsafeRawPointer], interpose: DynamicInterpose?) throws {
        guard let main = _dyld_get_image_header(0) else { throw LiveCodeError.noImage }
        if let interpose {
            tuples.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { interpose(main, base, tuples.count) }
            }
        }
        // dyld_dynamic_interpose leaves a pointer that is already bound on the old code: a `body`
        // SwiftUI called before this patch kept drawing the build's view. Repoint those too.
        let rebound = rebind(header: main, slide: _dyld_get_image_vmaddr_slide(0), to: targets)
        // Without dyld_dynamic_interpose the rebind is the whole repoint: none written, no call changed.
        if interpose == nil, rebound.written == 0 { throw LiveCodeError.noInterposer }
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
    @discardableResult
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

    /// The opaque result types (`some View`) whose underlying type the patch changed: a `body` that
    /// gained or lost a view or a modifier. The build's conformance still names the old type, so
    /// SwiftUI would read the new `body`'s value as the old type (a crash or garbage). Each opaque type
    /// descriptor (`…QOMQ`) the patch and this build both define names its underlying types by mangled
    /// name; both are resolved and their names compared. A descriptor of a generic context (its type
    /// needs generic arguments to resolve) or with packs or values is not compared.
    static func opaqueTypeChanges(header: UnsafePointer<mach_header>, slide: Int, mainOnly: UnsafeMutableRawPointer?) -> [String] {
        var changed: [String] = []
        for (name, theirs) in symbols(header: header, slide: slide, code: false) {
            guard name.hasPrefix("_$s"), name.hasSuffix("QOMQ"), let ours = dlsym(mainOnly, String(name.dropFirst())),
                  UnsafeRawPointer(ours) != theirs,
                  let old = underlyingTypeNames(UnsafeRawPointer(ours)), let new = underlyingTypeNames(theirs),
                  old != new else { continue }
            // The descriptor's symbol names the function or property whose result changed.
            changed.append(String(name.dropFirst().dropLast(4)))
        }
        return changed
    }

    /// The names of an opaque type descriptor's underlying types, or nil when they are not compared.
    static func underlyingTypeNames(_ descriptor: UnsafeRawPointer) -> [String]? {
        let flags = descriptor.load(as: UInt32.self)
        // Context descriptor kind 4 is an opaque type; its kind-specific flags count the underlying types.
        guard flags & 0x1F == 4, flags & 0x80 != 0 else { return nil }
        // The parent (a relative pointer, indirect when its low bit is set) must not be generic: then
        // the opaque type's generic parameters are its own `some` types, and their underlying types
        // resolve with no generic arguments.
        let parentField = descriptor + 4
        let parentOffset = Int(parentField.load(as: Int32.self))
        let parentAddress = parentField + (parentOffset & ~1)
        let parent = parentOffset & 1 == 0 ? parentAddress : parentAddress.load(as: UnsafeRawPointer?.self)
        guard let parent, parent.load(as: UInt32.self) & 0x80 == 0 else { return nil }
        // GenericContextDescriptorHeader: params, requirements, key arguments, flags (UInt16 each).
        let params = Int(descriptor.load(fromByteOffset: 8, as: UInt16.self))
        let requirements = Int(descriptor.load(fromByteOffset: 10, as: UInt16.self))
        guard descriptor.load(fromByteOffset: 14, as: UInt16.self) == 0, params <= Int(flags >> 16) else { return nil } // packs or values
        // Then a byte per parameter (padded to four), twelve per requirement, then a mangled name per
        // underlying type (one per parameter, first) and per conformance.
        let offset = 16 + ((params + 3) & ~3) + requirements * 12
        var names: [String] = []
        for index in 0..<params {
            let field = descriptor + offset + index * 4
            let mangled = (field + Int(field.load(as: Int32.self))).assumingMemoryBound(to: UInt8.self)
            guard let metadata = typeByMangledName(mangled, UInt(mangledNameLength(mangled)), descriptor, nil) else { return nil }
            // A private type prints as "(unknown context at $ADDRESS)", its context's address in
            // its own image: the build's and the patch's differ, the type does not.
            let printed = _typeName(unsafeBitCast(metadata, to: Any.Type.self), qualified: true)
            names.append(printed.replacing(/\(unknown context at \$[0-9a-f]+\)/, with: "(private)"))
        }
        return names
    }

    /// A mangled name's length: it ends at a zero byte, and a symbolic reference's bytes (after 0x01
    /// to 0x17: four, after 0x18 to 0x1F: eight) may hold zeros.
    private static func mangledNameLength(_ name: UnsafePointer<UInt8>) -> Int {
        var length = 0
        while true {
            let byte = name[length]
            if byte == 0 { return length }
            length += byte <= 0x17 ? 5 : byte <= 0x1F ? 9 : 1
        }
    }

    /// The external symbols defined in the image's `__TEXT,__text`: its functions, not its data.
    private static func codeSymbols(header: UnsafePointer<mach_header>, slide: Int) -> [(String, UnsafeRawPointer)] {
        symbols(header: header, slide: slide, code: true)
    }

    /// The image's external defined symbols: those in `__TEXT,__text` (`code`), or every other section's.
    static func symbols(header: UnsafePointer<mach_header>, slide: Int, code: Bool) -> [(String, UnsafeRawPointer)] {
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

/// The Swift runtime's lookup of a type by its mangled name, in the context that names it
/// (Interposer.underlyingTypeNames).
@_silgen_name("swift_getTypeByMangledNameInContext")
private func typeByMangledName(_ name: UnsafePointer<UInt8>, _ length: UInt, _ context: UnsafeRawPointer?,
                               _ arguments: UnsafeRawPointer?) -> UnsafeRawPointer?
#endif
