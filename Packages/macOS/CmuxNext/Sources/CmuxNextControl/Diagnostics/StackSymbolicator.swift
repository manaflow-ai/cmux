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

    /// One frame per address, in order. Resolves symbols; call off the main
    /// thread.
    public func frames(for addresses: [UInt]) -> [HangFrame] {
        let executable = _dyld_get_image_header(0).map { UnsafeRawPointer($0) }
        return addresses.map { address in
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
                return HangFrame(address: address, image: nil, symbol: nil, offset: 0)
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent }
            let imageOffset = info.dli_fbase.map { address &- UInt(bitPattern: $0) }
            if let map, let imageOffset, info.dli_fbase.map(UnsafeRawPointer.init) == executable,
               let function = map.function(at: imageOffset) {
                return HangFrame(address: address, image: image, symbol: Self.demangle(function.name),
                                 offset: function.offset, imageOffset: imageOffset)
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
