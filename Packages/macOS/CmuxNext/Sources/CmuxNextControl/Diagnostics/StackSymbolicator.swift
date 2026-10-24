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
public struct StackSymbolicator: Sendable {
    let map: AppSymbolMap?

    /// - Parameter map: The app executable's names. Defaults to the running
    ///   executable's map, nil in builds without one.
    public init(map: AppSymbolMap? = AppSymbolMap.main) {
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
        let executable = _dyld_get_image_header(0).map { UnsafeRawPointer($0) }
        // Each image's function starts and UUID, read once per stack (images repeat within one stack).
        var startsByImage: [UInt: FunctionStarts?] = [:]
        var uuidByImage: [UInt: String?] = [:]
        func functionStarts(_ header: UnsafeMutableRawPointer) -> FunctionStarts? {
            let key = UInt(bitPattern: header)
            if let known = startsByImage[key] { return known }
            let read = FunctionStarts.read(header: UnsafeRawPointer(header))
            startsByImage[key] = .some(read)
            return read
        }
        func uuid(_ header: UnsafeMutableRawPointer) -> String? {
            let key = UInt(bitPattern: header)
            if let known = uuidByImage[key] { return known }
            let read = FunctionStarts.uuid(header: UnsafeRawPointer(header))
            uuidByImage[key] = .some(read)
            return read
        }
        return addresses.enumerated().map { index, address in
            var frame = frame(index: index, address: address, executable: executable, functionStarts: functionStarts)
            if frame.imageOffset != nil, let header = UnsafeMutableRawPointer(bitPattern: address &- (frame.imageOffset ?? 0)) {
                frame.imageUUID = uuid(header)
            }
            return frame
        }
    }

    /// One address's frame (``frames(for:)``): the app's own map first, else `dladdr` checked
    /// against the image's function starts.
    private func frame(index: Int, address: UInt, executable: UnsafeRawPointer?,
                       functionStarts: (UnsafeMutableRawPointer) -> FunctionStarts?) -> HangFrame {
        var info = Dl_info()
        let lookup = index == 0 || address == 0 ? address : address &- 1
        guard let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 else {
            return HangFrame(address: address, image: nil, symbol: nil, offset: 0)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent }
        let imageOffset = info.dli_fbase.map { address &- UInt(bitPattern: $0) }
        let lookupOffset = info.dli_fbase.map { lookup &- UInt(bitPattern: $0) }
        if let map, let imageOffset, let lookupOffset, info.dli_fbase.map(UnsafeRawPointer.init) == executable,
           let function = map.function(at: lookupOffset) {
            // The offset into the function, counted from the reported address.
            return HangFrame(address: address, image: image, symbol: Self.demangle(function.name),
                             offset: function.offset &+ (address &- lookup), imageOffset: imageOffset)
        }
        let symbolOffset = info.dli_saddr.flatMap { saddr in info.dli_fbase.map { UInt(bitPattern: saddr) &- UInt(bitPattern: $0) } }
        return Self.frame(address: address, lookup: lookup, image: image, imageOffset: imageOffset,
                          symbol: info.dli_sname.map { String(cString: $0) }, symbolOffset: symbolOffset,
                          starts: info.dli_fbase.flatMap(functionStarts))
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
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return name }
        return name.withCString { raw in
            guard let result = swiftDemangle(raw, strlen(raw), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
