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
        return addresses.enumerated().map { index, address in
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
            let symbol = info.dli_sname.map { Self.demangle(String(cString: $0)) }
            let base = info.dli_saddr.map { UInt(bitPattern: $0) } ?? address
            return HangFrame(address: address, image: image, symbol: symbol, offset: address &- base,
                             imageOffset: imageOffset)
        }
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: Demangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return name }
        return name.withCString { raw in
            guard let result = swiftDemangle(raw, strlen(raw), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
