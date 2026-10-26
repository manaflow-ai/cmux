#if DEBUG || CMUX_BENCH_HOOKS
import Darwin
import Foundation
import MachO

/// Turns a hop's return addresses into image + offset frames, caching each image's name and UUID,
/// and picks the frame that names the hop's site. Runs in the fold only, never on the main thread
/// (`dladdr` takes dyld's lock), as BlockingFrameResolver does for the blocking detector.
struct HopFrameResolver {
    /// One loaded image.
    struct Image: Sendable, Equatable {
        var name: String
        var uuid: String?
        /// The Swift concurrency runtime, the Swift core library, libdispatch or its Swift overlay:
        /// the frames a job's enqueue passes through on its way to the main executor, never its site.
        var isRuntime: Bool
    }

    /// One resolved return address.
    struct Resolved: Sendable, Equatable {
        var base: UInt
        var image: Image
        /// The return address minus the image's load address.
        var offset: UInt
        /// `dladdr`'s nearest exported symbol before the call (mangled), when there is one.
        var nearestSymbol: String?
    }

    static let runtimeImages: Set<String> = ["libswift_Concurrency.dylib", "libswiftCore.dylib", "libdispatch.dylib", "libswiftDispatch.dylib"]

    private var images: [UInt: Image] = [:]

    /// The frame of `address`; nil outside every loaded image (a test's made-up address).
    mutating func resolve(_ address: UInt) -> Resolved? {
        var info = Dl_info()
        // A return address can sit just past its function (a call that does not return): look up the call.
        guard address > 0, let pointer = UnsafeRawPointer(bitPattern: address - 1), dladdr(pointer, &info) != 0,
              let header = info.dli_fbase else { return nil }
        let base = UInt(bitPattern: header)
        let image = images[base] ?? Self.image(header: header, path: info.dli_fname)
        images[base] = image
        let symbol = info.dli_sname.map { String(cString: $0) }
        return Resolved(base: base, image: image, offset: address - base, nearestSymbol: symbol)
    }

    /// The index of the frame that names the site: the first frame after the runtime frames the
    /// enqueue went through (the hook and the recorder come before them), else the first frame
    /// (a direct call with no runtime frame: tests). `isRuntime` per frame, innermost first; nil
    /// for an unresolved frame. Nil when the stack is empty.
    static func siteIndex(_ isRuntime: [Bool?]) -> Int? {
        guard !isRuntime.isEmpty else { return nil }
        guard let firstRuntime = isRuntime.firstIndex(where: { $0 == true }) else { return 0 }
        return isRuntime[firstRuntime...].firstIndex(where: { $0 != true }) ?? isRuntime.count - 1
    }

    private static func image(header: UnsafeMutableRawPointer, path: UnsafePointer<CChar>?) -> Image {
        let name = path.map { String(cString: $0) }.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "?"
        return Image(name: name, uuid: uuid(header.assumingMemoryBound(to: mach_header_64.self))?.uuidString,
                     isRuntime: runtimeImages.contains(name))
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
