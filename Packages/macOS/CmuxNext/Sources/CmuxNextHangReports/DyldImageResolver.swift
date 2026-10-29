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
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)), dladdr(pointer, &info) != 0,
              let base = info.dli_fbase else { return nil }
        let path = info.dli_fname.map { String(cString: $0) } ?? ""
        return Self.image(header: base.assumingMemoryBound(to: mach_header_64.self), path: path)
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
            guard let header = _dyld_get_image_header(index) else { continue }
            var info = Dl_info()
            guard dladdr(header, &info) != 0, let base = info.dli_fbase, UnsafeRawPointer(base) == UnsafeRawPointer(header),
                  let name = info.dli_fname else { continue }
            let image = Self.image(header: UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self), path: String(cString: name))
            if image?.uuid == wanted { return image }
        }
        return nil
    }

    /// The image at `header`: its LC_UUID and `__TEXT` size; nil for a 32-bit or UUID-less image,
    /// or load commands that do not fit their declared size.
    private static func image(header: UnsafePointer<mach_header_64>, path: String) -> LoadedImage? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var uuid: String?
        var textSize: UInt64 = 0
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var remaining = Int(header.pointee.sizeofcmds)
        for _ in 0..<header.pointee.ncmds {
            guard remaining >= MemoryLayout<load_command>.size else { return nil }
            let load = command.load(as: load_command.self)
            guard Int(load.cmdsize) >= MemoryLayout<load_command>.size, Int(load.cmdsize) <= remaining else { return nil }
            remaining -= Int(load.cmdsize)
            if load.cmd == LC_UUID, Int(load.cmdsize) >= MemoryLayout<uuid_command>.size {
                uuid = UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            } else if load.cmd == LC_SEGMENT_64, Int(load.cmdsize) >= MemoryLayout<segment_command_64>.size {
                var segment = command.load(as: segment_command_64.self)
                let name = withUnsafeBytes(of: &segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { textSize = segment.vmsize }
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        guard let uuid, textSize > 0 else { return nil }
        return LoadedImage(path: path, uuid: uuid, base: UInt64(UInt(bitPattern: header)), size: textSize)
    }
}
