import Darwin
import Foundation
import MachO

/// ``ImageResolving`` over this process's dyld image list. Runs off the main thread, when a
/// report or a stall's stack is resolved (it walks load commands and allocates).
public nonisolated struct DyldImageResolver: ImageResolving {
    /// Makes the value from its parts.
    public init() {}

    /// Looks up a loaded image (``ImageResolving``).
    public func image(containing address: UInt64) -> LoadedImage? {
        var info = Dl_info()
        // SAFETY: dladdr only looks the address up in dyld's image list (never dereferences it) and fills `info`,
        // a local; dli_fbase is then the mach header of a loaded image and dli_fname its NUL-terminated path.
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: UInt(address)), unsafe dladdr(pointer, &info) != 0,
              let base = unsafe info.dli_fbase else { return nil }
        // SAFETY: as above; String(cString:) copies the path.
        let path = unsafe info.dli_fname.map { unsafe String(cString: $0) } ?? ""
        // SAFETY: as above: `base` is a loaded image's mach header.
        return unsafe Self.image(header: base.assumingMemoryBound(to: mach_header_64.self), path: path)
    }

    /// Looks up a loaded image (``ImageResolving``).
    ///
    /// The index APIs are not safe against a concurrent `dlclose`: an index can shift between
    /// `_dyld_get_image_header` and `_dyld_get_image_name`. So the path is never read by index:
    /// `dladdr` on the header (under dyld's lock) confirms the image is still loaded and gives
    /// the path of that same image, so a UUID is never paired with another image's path.
    public func image(uuid: String) -> LoadedImage? {
        let wanted = uuid.uppercased()
        for index in 0..<_dyld_image_count() {
            // SAFETY: the header pointer is only compared and passed to dladdr until dladdr confirms it (below).
            guard let header = unsafe _dyld_get_image_header(index) else { continue }
            var info = Dl_info()
            // SAFETY: dladdr fills `info`, a local; a dli_fbase equal to `header` confirms a loaded image's mach
            // header, and dli_fname is that image's NUL-terminated path, which String(cString:) copies.
            guard unsafe dladdr(header, &info) != 0, let base = unsafe info.dli_fbase,
                  unsafe UnsafeRawPointer(base) == UnsafeRawPointer(header), let name = unsafe info.dli_fname else { continue }
            // SAFETY: as above.
            let image = unsafe Self.image(header: UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self),
                                          path: String(cString: name))
            if image?.uuid == wanted { return image }
        }
        return nil
    }

    /// The image at `header`: its LC_UUID and `__TEXT` size; nil for a 32-bit or UUID-less image,
    /// or load commands that do not fit their declared size.
    // SAFETY (the walk): `header` is a loaded image's mach header (confirmed by dladdr), mapped while the image
    // stays loaded; every load reads a whole command that lies inside the header's `sizeofcmds` bytes after it,
    // checked before the load.
    @unsafe private static func image(header: UnsafePointer<mach_header_64>, path: String) -> LoadedImage? {
        // SAFETY: as above (the walk): the header itself is mapped.
        guard unsafe header.pointee.magic == MH_MAGIC_64 else { return nil }
        var uuid: String?
        var textSize: UInt64 = 0
        // SAFETY: as above (the walk).
        var command = unsafe UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        // SAFETY: as above (the walk).
        var remaining = unsafe Int(header.pointee.sizeofcmds)
        // SAFETY: as above (the walk).
        let commandCount = unsafe header.pointee.ncmds
        for _ in 0..<commandCount {
            guard remaining >= MemoryLayout<load_command>.size else { return nil }
            // SAFETY: as above (the walk): a load_command's bytes remain.
            let load = unsafe command.load(as: load_command.self)
            guard Int(load.cmdsize) >= MemoryLayout<load_command>.size, Int(load.cmdsize) <= remaining else { return nil }
            remaining -= Int(load.cmdsize)
            if load.cmd == LC_UUID, Int(load.cmdsize) >= MemoryLayout<uuid_command>.size {
                // SAFETY: as above (the walk): the command holds a whole uuid_command.
                uuid = unsafe UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            } else if load.cmd == LC_SEGMENT_64, Int(load.cmdsize) >= MemoryLayout<segment_command_64>.size {
                // SAFETY: as above (the walk): the command holds a whole segment_command_64.
                var segment = unsafe command.load(as: segment_command_64.self)
                // SAFETY: reads the 16 bytes of `segname`, a tuple in the local copy, only inside the closure.
                let name = unsafe withUnsafeBytes(of: &segment.segname) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { textSize = segment.vmsize }
            }
            // SAFETY: as above (the walk): the next command starts inside the checked bytes, or the loop ends.
            command = unsafe command.advanced(by: Int(load.cmdsize))
        }
        guard let uuid, textSize > 0 else { return nil }
        // SAFETY: the header's address as an integer, the image's load address.
        return unsafe LoadedImage(path: path, uuid: uuid, base: UInt64(UInt(bitPattern: header)), size: textSize)
    }
}
