import Accelerate
import CmuxNextCompat
import CoreGraphics
import Darwin
import Foundation

/// A read-only map of the frame ring of one helper window stream (cmux-cua
/// `platform-macos/src/application_surface.rs`, `application_surface_start`). The helper owns and
/// writes it; this process only reads the newest frame, scaled down.
///
/// Layout: a 64-byte header (magic `CMXF`, version 2, width, height, bytes per row, slot count,
/// byte count; at 32 the published word `sequence << 2 | slot`; at 40 + 8 * slot that slot's
/// version, odd while the helper writes it and `sequence * 2` once done), then three slots of BGRA
/// pixels (premultiplied, little-endian 32-bit). The window's rounded corners are transparent.
///
/// Sendable with no lock: every stored value is set once in `init`; the mapping is read only, and
/// its address is kept as an integer.
nonisolated final class ComputerUseFrameRing: Sendable {
    enum Failure: Error, Equatable {
        /// The transport is not a helper frame ring this reader knows.
        case unsupported
        /// The ring could not be opened or mapped (errno).
        case unavailable(Int32)
    }

    static let magic: UInt32 = 0x434D_5846
    static let version: UInt32 = 2
    static let headerBytes = 64
    static let publishedOffset = 32
    static let slotVersionOffset = 40
    static let slots = 3
    /// The helper's own bounds: a side of at most 16384 pixels, a ring of at most 256 MB.
    static let maximumSide = 16_384
    static let maximumBytes = 256 << 20
    /// Only the helper's rings are mapped (`/cmux-sim-frame-<12 hex>`).
    static let namePrefix = "/cmux-sim-frame-"

    let width: Int
    let height: Int
    let bytesPerRow: Int
    let byteCount: Int
    /// The mapping's address.
    private let address: UInt
    private let release: @Sendable (UnsafeRawPointer, Int) -> Void

    /// Maps the ring `application_surface_start` named in its `frameTransport`.
    convenience init(transport: [String: Any]) throws {
        func int(_ key: String) -> Int { (transport[key] as? NSNumber)?.intValue ?? 0 }
        guard let name = transport["sharedMemoryName"] as? String else { throw Failure.unsupported }
        try self.init(name: name, byteCount: int("sharedMemoryByteCount"), width: int("width"), height: int("height"),
                      bytesPerRow: int("bytesPerRow"), slotCount: int("slotCount"))
    }

    convenience init(name: String, byteCount: Int, width: Int, height: Int, bytesPerRow: Int, slotCount: Int) throws {
        // PSHMNAMLEN is 31: the helper's names are 28.
        guard name.hasPrefix(Self.namePrefix), name.utf8.count <= 31, slotCount == Self.slots,
              Self.fits(byteCount: byteCount, width: width, height: height, bytesPerRow: bytesPerRow)
        else { throw Failure.unsupported }
        let descriptor = Self.openReadOnly(name)
        guard descriptor >= 0 else { throw Failure.unavailable(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Int(info.st_size) >= byteCount else { throw Failure.unavailable(EINVAL) }
        let mapping = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != MAP_FAILED else { throw Failure.unavailable(errno) }
        try self.init(mapping: UnsafeRawPointer(mapping), byteCount: byteCount, width: width, height: height,
                      bytesPerRow: bytesPerRow) { munmap(UnsafeMutableRawPointer(mutating: $0), $1) }
    }

    /// A ring over `mapping` (`byteCount` bytes, at least 8-byte aligned) whose header names this
    /// geometry; `release` frees the mapping when the ring goes (tests pass their own memory).
    init(mapping: UnsafeRawPointer, byteCount: Int, width: Int, height: Int, bytesPerRow: Int,
         release: @escaping @Sendable (UnsafeRawPointer, Int) -> Void) throws {
        let header = mapping
        guard Self.fits(byteCount: byteCount, width: width, height: height, bytesPerRow: bytesPerRow),
              header.loadUnaligned(as: UInt32.self) == Self.magic,
              header.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == Self.version,
              Int(header.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) == width,
              Int(header.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) == height,
              Int(header.loadUnaligned(fromByteOffset: 16, as: UInt32.self)) == bytesPerRow,
              Int(header.loadUnaligned(fromByteOffset: 20, as: UInt32.self)) == Self.slots else {
            release(mapping, byteCount)
            throw Failure.unsupported
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.byteCount = byteCount
        self.release = release
        address = UInt(bitPattern: header)
    }

    deinit {
        if let base = UnsafeRawPointer(bitPattern: address) { release(base, byteCount) }
    }

    /// Whether the geometry is one the helper makes: sides of 1 to 16384 pixels, rows of four bytes
    /// a pixel or more, three slots after the header, at most 256 MB in all.
    static func fits(byteCount: Int, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        (1...maximumSide).contains(width) && (1...maximumSide).contains(height) && bytesPerRow >= width * 4
            && bytesPerRow <= maximumSide * 4 && byteCount >= headerBytes + slots * bytesPerRow * height && byteCount <= maximumBytes
    }

    /// The newest frame when its sequence is past `after`, scaled to `longSide` pixels on its long
    /// side: its sequence and image. Nil when the helper published nothing newer, or rewrote the
    /// slot while it was read (the next read takes the frame after it).
    func newest(after: UInt64, longSide: Int) -> (sequence: UInt64, image: CGImage)? {
        guard let base = UnsafeRawPointer(bitPattern: address) else { return nil }
        let published = SharedMemoryWord(base + Self.publishedOffset).loadAcquiring()
        let sequence = published >> 2, slot = Int(published & 3)
        guard sequence > after, slot < Self.slots else { return nil }
        let version = SharedMemoryWord(base + Self.slotVersionOffset + 8 * slot)
        guard version.loadAcquiring() == sequence &* 2 else { return nil }
        let image = scaled(base + Self.headerBytes + slot * bytesPerRow * height, longSide: longSide)
        // A slot the helper started again while it was scaled is dropped (seqlock).
        guard version.loadAfterReads() == sequence &* 2 else { return nil }
        return image.map { (sequence, $0) }
    }

    /// The pixel size a frame of `width` x `height` scales to: `longSide` on its long side, never larger.
    static func scaledSize(width: Int, height: Int, longSide: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(longSide) / Double(max(width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// The slot at `pixels`, scaled.
    private func scaled(_ pixels: UnsafeRawPointer, longSide: Int) -> CGImage? {
        let size = Self.scaledSize(width: width, height: height, longSide: longSide)
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: bytesPerRow)
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let out = context.data else { return nil }
        var destination = vImage_Buffer(data: out, height: vImagePixelCount(size.height), width: vImagePixelCount(size.width),
                                        rowBytes: context.bytesPerRow)
        // Channel order does not matter to the scale; BGRA in, BGRA out.
        guard vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return context.makeImage()
    }

    /// `shm_open(name, O_RDONLY)`, close-on-exec. Swift does not import the variadic C function; a
    /// read-only open passes no mode, so it is called through its symbol with the two named
    /// arguments only. shm_open refuses O_CLOEXEC (EINVAL), so the flag is set after; the caller
    /// closes the descriptor once the ring is mapped.
    private static func openReadOnly(_ name: String) -> Int32 {
        guard let shmOpen else { return -1 }
        let descriptor = name.withCString { shmOpen($0, O_RDONLY) }
        if descriptor >= 0 { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        return descriptor
    }

    private typealias SharedMemoryOpen = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private static let shmOpen: SharedMemoryOpen? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open")
        .map { unsafeBitCast($0, to: SharedMemoryOpen.self) }
}
