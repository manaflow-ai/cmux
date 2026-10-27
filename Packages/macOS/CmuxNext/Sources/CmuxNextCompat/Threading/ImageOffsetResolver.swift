#if DEBUG || CMUX_BLOCKING_CHECKS || CMUX_BENCH_HOOKS
internal import Darwin
package import Foundation
internal import MachO

/// Turns a return address into its loaded image (name and `LC_UUID`) and its offset in it: enough
/// to symbolicate it later with the image's dSYM. Caches each image. `dladdr` takes dyld's lock, so
/// the blocking detector's drain (``BlockingFrameResolver``) and the input-turn hop recorder's fold
/// (CmuxNextWakeups) call it, never the main thread.
///
/// ```swift
/// var resolver = ImageOffsetResolver()
/// if let frame = resolver.resolve(returnAddress) { print(frame.image.name, frame.offset) }
/// ```
package struct ImageOffsetResolver: Sendable {
    /// One loaded image.
    package struct Image: Sendable, Equatable {
        /// The file name of the image's path (`CoreFoundation`, `libdispatch.dylib`, `cmux DEV`).
        package var name: String
        package var uuid: UUID?

        package init(name: String, uuid: UUID?) {
            self.name = name
            self.uuid = uuid
        }
    }

    /// One resolved return address.
    package struct Resolved: Sendable, Equatable {
        /// The image's load address.
        package var base: UInt
        package var image: Image
        /// The return address minus ``base``.
        package var offset: UInt
        /// `dladdr`'s nearest symbol before the call (mangled), when there is one.
        package var nearestSymbol: String?

        package init(base: UInt, image: Image, offset: UInt, nearestSymbol: String?) {
            self.base = base
            self.image = image
            self.offset = offset
            self.nearestSymbol = nearestSymbol
        }
    }

    private var images: [UInt: Image] = [:]

    package init() {}

    /// The image and offset of `address`; nil outside every loaded image.
    package mutating func resolve(_ address: UInt) -> Resolved? {
        var info = Dl_info()
        // A return address can sit just past its function (a call that does not return): look up the call.
        // SAFETY: dladdr only looks the address up (it never dereferences it) and writes one Dl_info into `info`, a
        // local. Its strings and header belong to an image dyld keeps loaded (cmux never unloads one); they are
        // copied out (String, UInt, UUID) before this returns.
        guard address > 1, let pointer = unsafe UnsafeRawPointer(bitPattern: address - 1), unsafe dladdr(pointer, &info) != 0,
              let header = unsafe info.dli_fbase else { return nil }
        let base = unsafe UInt(bitPattern: header)
        let image = unsafe images[base] ?? Self.image(header: header, path: info.dli_fname)
        images[base] = image
        return Resolved(base: base, image: image, offset: address - base,
                        nearestSymbol: unsafe info.dli_sname.map { unsafe String(cString: $0) })
    }

    /// Reads the image's name and UUID; `header` and `path` are dladdr's, valid while the image is loaded.
    private static func image(header: UnsafeMutableRawPointer, path: UnsafePointer<CChar>?) -> Image {
        // SAFETY: `path` is dladdr's NUL-terminated image path (see resolve), copied into a String here.
        let name = unsafe path.map { unsafe String(cString: $0) }.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "?"
        return Image(name: name, uuid: unsafe uuid(UnsafeRawPointer(header)))
    }

    /// The `LC_UUID` of a loaded 64-bit image whose mach header is at `header`. Every read stays inside the
    /// header and its `sizeofcmds` bytes of load commands, as Chromium's Mach-O reader bounds each command
    /// (base/mac/mach_o.cc, `MachOImageReader`); a command that runs past them ends the walk.
    private static func uuid(_ header: UnsafeRawPointer) -> UUID? {
        // SAFETY: `header` is a loaded image's base (dladdr's dli_fbase), which starts with a mach header that dyld
        // keeps mapped while the image is loaded.
        let top = unsafe header.loadUnaligned(as: mach_header_64.self)
        guard top.magic == UInt32(MH_MAGIC_64) else { return nil }
        let commands = unsafe header + MemoryLayout<mach_header_64>.size
        let end = Int(top.sizeofcmds)
        var offset = 0
        for _ in 0..<top.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { return nil }
            // SAFETY: the command's header lies inside the sizeofcmds bytes after the mach header (checked above),
            // which the loaded image maps.
            let load = unsafe commands.loadUnaligned(fromByteOffset: offset, as: load_command.self)
            let size = Int(load.cmdsize)
            guard size >= MemoryLayout<load_command>.size, offset + size <= end else { return nil }
            if load.cmd == UInt32(LC_UUID) {
                guard size >= MemoryLayout<uuid_command>.size else { return nil }
                // SAFETY: the whole uuid_command lies inside this command's cmdsize bytes (checked above).
                return UUID(uuid: unsafe commands.loadUnaligned(fromByteOffset: offset, as: uuid_command.self).uuid)
            }
            offset += size
        }
        return nil
    }
}
#endif
