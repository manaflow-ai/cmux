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
        guard address > 1, let pointer = UnsafeRawPointer(bitPattern: address - 1), dladdr(pointer, &info) != 0,
              let header = info.dli_fbase else { return nil }
        let base = UInt(bitPattern: header)
        let image = images[base] ?? Self.image(header: header, path: info.dli_fname)
        images[base] = image
        return Resolved(base: base, image: image, offset: address - base, nearestSymbol: info.dli_sname.map { String(cString: $0) })
    }

    private static func image(header: UnsafeMutableRawPointer, path: UnsafePointer<CChar>?) -> Image {
        let name = path.map { String(cString: $0) }.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "?"
        return Image(name: name, uuid: uuid(header.assumingMemoryBound(to: mach_header_64.self)))
    }

    /// The `LC_UUID` of a loaded 64-bit image.
    private static func uuid(_ header: UnsafePointer<mach_header_64>) -> UUID? {
        guard header.pointee.magic == UInt32(MH_MAGIC_64) else { return nil }
        var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.assumingMemoryBound(to: uuid_command.self).pointee.uuid)
            }
            command += Int(load.cmdsize)
        }
        return nil
    }
}
#endif
