#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin
internal import Foundation
internal import MachO

/// Turns return addresses into ``BlockingFrame``s (image UUID + offset), caching each image's
/// UUID. Runs on the drain queue only (`dladdr` takes dyld's lock).
struct BlockingFrameResolver {
    private var uuids: [UInt: UUID?] = [:]

    /// The frames of `addresses`; an address outside a loaded image with a UUID is left out.
    mutating func frames(_ addresses: [UInt]) -> [BlockingFrame] {
        addresses.compactMap { address in
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0,
                  let header = info.dli_fbase else { return nil }
            let base = UInt(bitPattern: header)
            if uuids[base] == nil { uuids[base] = .some(imageUUID(header.assumingMemoryBound(to: mach_header_64.self))) }
            guard let uuid = uuids[base] ?? nil else { return nil }
            return BlockingFrame(imageUUID: uuid, offset: UInt64(address - base))
        }
    }
}

/// The `LC_UUID` of a loaded 64-bit image.
private func imageUUID(_ header: UnsafePointer<mach_header_64>) -> UUID? {
    var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
    for _ in 0..<header.pointee.ncmds {
        let load = command.assumingMemoryBound(to: load_command.self).pointee
        if load.cmd == UInt32(LC_UUID) {
            let uuid = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
            return UUID(uuid: uuid)
        }
        command += Int(load.cmdsize)
    }
    return nil
}
#endif
