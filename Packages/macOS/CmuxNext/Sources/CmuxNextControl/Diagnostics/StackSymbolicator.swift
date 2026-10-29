import Darwin
import Foundation
import MachO

/// Resolves return addresses to image, function, and offset for hang records
/// and exception traces.
///
/// Frames in the app executable resolve through its ``AppSymbolMap`` when
/// there is one (release builds strip the executable's names); every other
/// image resolves through `dladdr`. A frame with no name still carries its
/// offset from the image header, which the build's dSYM resolves.
///
/// Memory safety: an image is known here only by its load address, an integer. The one pointer made from it is
/// the header of an image `dladdr` just found mapped (``FunctionStarts`` reads it; images the stacks run in are
/// never unloaded), and the names `dladdr` returns are copied out at once.
public struct StackSymbolicator: Sendable {
    let map: AppSymbolMap?

    /// - Parameter map: The app executable's names (``AppSymbolMap/loadMain()``, read
    ///   by the caller off the main thread), nil in builds without one.
    public init(map: AppSymbolMap?) {
        self.map = map
    }

    /// One frame per address, in order, the first being where the thread
    /// was and the rest return addresses. Resolves symbols; call off the main
    /// thread.
    ///
    /// A return address is the instruction after its call, which is the next
    /// function's first one after a call to a function that never returns, so
    /// frames after the first resolve `address - 1`, the call itself. Each
    /// frame still reports its address, and offsets count from it.
    public func frames(for addresses: [UInt]) -> [HangFrame] {
        let executable = AppSymbolMap.executableImage()?.loadAddress
        // Each image's function starts and UUID, read once per stack (images repeat within one stack).
        var startsByImage: [UInt: FunctionStarts?] = [:]
        var uuidByImage: [UInt: String?] = [:]
        func functionStarts(_ base: UInt) -> FunctionStarts? {
            if let known = startsByImage[base] { return known }
            // SAFETY: the header of the image dladdr found at `base` (header(at:)).
            let read = unsafe Self.header(at: base).flatMap { unsafe FunctionStarts.read(header: $0) }
            startsByImage[base] = .some(read)
            return read
        }
        func uuid(_ base: UInt) -> String? {
            if let known = uuidByImage[base] { return known }
            // SAFETY: as in functionStarts.
            let read = unsafe Self.header(at: base).flatMap { unsafe FunctionStarts.uuid(header: $0) }
            uuidByImage[base] = .some(read)
            return read
        }
        return addresses.enumerated().map { index, address in
            var frame = frame(index: index, address: address, executable: executable, functionStarts: functionStarts)
            if let imageOffset = frame.imageOffset, address &- imageOffset != 0 {
                frame.imageUUID = uuid(address &- imageOffset)
            }
            return frame
        }
    }

    /// The Mach-O header at `base`, the load address `dladdr` reported for a frame's image; nil for 0.
    private static func header(at base: UInt) -> UnsafeRawPointer? {
        // SAFETY: `base` is the dli_fbase dladdr returned for a mapped image (the struct's note); a pointer is
        // made only to hand that header to FunctionStarts, which reads inside its load commands.
        unsafe UnsafeRawPointer(bitPattern: base)
    }

    /// The function at `imageOffset` in the running executable, for a frame another process
    /// recorded (the previous run's macOS crash report): nil unless `uuid` is this executable's
    /// `LC_UUID` (the same build), or when no name is found. Call off the main thread.
    ///
    /// - Parameters:
    ///   - uuid: The frame's image UUID as the report wrote it (any case).
    ///   - imageOffset: The frame's offset from the image header.
    ///   - returnAddress: The frame is a return address (every frame but the crashed one).
    /// - Returns: The demangled function and the offset into it.
    public func executableFunction(uuid: String, imageOffset: UInt, returnAddress: Bool) -> (symbol: String, offset: UInt)? {
        guard let header = _dyld_get_image_header(0), let own = AppSymbolMap.uuid(of: header),
              own.uuidString.caseInsensitiveCompare(uuid) == .orderedSame else { return nil }
        let base = UInt(bitPattern: header)
        let found = frame(index: returnAddress ? 1 : 0, address: base &+ imageOffset, executable: UnsafeRawPointer(header),
                          functionStarts: { FunctionStarts.read(header: UnsafeRawPointer($0)) })
        guard let symbol = found.symbol else { return nil }
        return (symbol, found.offset)
    }

    /// One address's frame (``frames(for:)``): the app's own map first, else `dladdr` checked
    /// against the image's function starts.
    private func frame(index: Int, address: UInt, executable: UInt?,
                       functionStarts: (UInt) -> FunctionStarts?) -> HangFrame {
        let lookup = index == 0 || address == 0 ? address : address &- 1
        guard let info = Self.imageInfo(lookup) else {
            return HangFrame(address: address, image: nil, symbol: nil, offset: 0)
        }
        let image = info.path.map { ($0 as NSString).lastPathComponent }
        let imageOffset = info.base.map { address &- $0 }
        let lookupOffset = info.base.map { lookup &- $0 }
        if let map, let imageOffset, let lookupOffset, info.base == executable,
           let function = map.function(at: lookupOffset) {
            // The offset into the function, counted from the reported address.
            return HangFrame(address: address, image: image, symbol: Self.demangle(function.name),
                             offset: function.offset &+ (address &- lookup), imageOffset: imageOffset)
        }
        let symbolOffset = info.symbolAddress.flatMap { saddr in info.base.map { saddr &- $0 } }
        return Self.frame(address: address, lookup: lookup, image: image, imageOffset: imageOffset,
                          symbol: info.symbol, symbolOffset: symbolOffset,
                          starts: info.base.flatMap(functionStarts))
    }

    /// What `dladdr` knows of `address`, copied out of its `Dl_info`: the image's path and load address, and the
    /// nearest symbol before the address and its address. Nil when no loaded image holds the address.
    private static func imageInfo(_ address: UInt) -> (path: String?, base: UInt?, symbol: String?, symbolAddress: UInt?)? {
        var info = Dl_info()
        // SAFETY: dladdr only looks the address up in dyld's image list (it never dereferences it) and fills
        // `info`, a local live for the call; a nonzero pointer from bitPattern is only that lookup key.
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: address), unsafe dladdr(pointer, &info) != 0 else { return nil }
        // SAFETY: dli_fname and dli_sname are nil or NUL-terminated strings dyld owns for the loaded image, copied
        // here; dli_fbase and dli_saddr are read only as integers.
        let path = unsafe info.dli_fname.map { unsafe String(cString: $0) }
        let symbol = unsafe info.dli_sname.map { unsafe String(cString: $0) }
        let base = unsafe info.dli_fbase.map { unsafe UInt(bitPattern: $0) }
        let symbolAddress = unsafe info.dli_saddr.map { unsafe UInt(bitPattern: $0) }
        return (path, base, symbol, symbolAddress)
    }

    /// One frame from `dladdr`'s fields: `symbol` (mangled) at `symbolOffset` from the image header,
    /// the address at `imageOffset`, `lookup` the address looked up (the call for a return address).
    /// `starts` is the image's function starts, nil when it has none.
    static func frame(address: UInt, lookup: UInt, image: String?, imageOffset: UInt?, symbol: String?, symbolOffset: UInt?,
                      starts: FunctionStarts?) -> HangFrame {
        // dladdr names the nearest exported symbol before the address. A function that starts in
        // between (a stripped local one, such as libswift_Concurrency's executor and job frames) proves
        // that name wrong: the frame keeps only its image and offset, which the build's dSYM resolves
        // (never "swift_Concurrency_fatalError + 43120").
        let lookupOffset = imageOffset.map { $0 &- (address &- lookup) }
        guard let symbol, let symbolOffset, let imageOffset, let lookupOffset,
              starts?.startsBetween(symbolOffset: symbolOffset, addressOffset: lookupOffset) != true else {
            return HangFrame(address: address, image: image, symbol: nil, offset: 0, imageOffset: imageOffset)
        }
        return HangFrame(address: address, image: image, symbol: demangle(symbol), offset: imageOffset &- symbolOffset,
                         imageOffset: imageOffset)
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: Demangle? = {
        // SAFETY: RTLD_DEFAULT (-2) searches every loaded image; swift_demangle, when found, is the Swift runtime's
        // exported C function, whose signature `Demangle` states (swift/Runtime/Debug.h, swift_demangle).
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafe unsafeBitCast(symbol, to: Demangle.self)
    }()

    static func demangle(_ name: String) -> String {
        // SAFETY: reads the function pointer swiftDemangle holds, set once from dlsym (see there).
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle = unsafe swiftDemangle else { return name }
        // SAFETY: `raw` is the name's NUL-terminated copy, live for the closure; swift_demangle reads strlen(raw)
        // bytes of it and, given no output buffer, returns nil or a malloc'd NUL-terminated string, copied here and
        // freed exactly once.
        return unsafe name.withCString { raw in
            guard let result = unsafe swiftDemangle(raw, strlen(raw), nil, nil, 0) else { return name }
            defer { unsafe free(result) }
            return unsafe String(cString: result)
        }
    }
}
