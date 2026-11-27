#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// ``ScreenRules`` from libcmux_rd_screen.dylib (cmux-tui/crates/cmux-rd-screen-ffi, its header
/// include/cmux_rd_screen.h), for a process that runs a host outside the app: cmux Remote's Screen
/// Sharing worker (the dylib in its Contents/Frameworks) and cmux-vnc-host (the dylib beside it).
/// The app hands its hosts CCmuxAppFFI's channel instead, and the phone cmux-mobile-link-ffi's.
extension ScreenRules {
    /// The library's file name.
    public static let libraryName = "libcmux_rd_screen.dylib"

    /// The rules of the library this process ships, found once: `CMUX_RD_SCREEN_DYLIB`, else the
    /// running bundle's Frameworks, else the executable's folder. None (the full display, the cursor
    /// in the picture, no focus signals) when there is no library there.
    public static let bundled: ScreenRules = {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["CMUX_RD_SCREEN_DYLIB"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent(libraryName))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(libraryName))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let rules = library(at: url) { return rules }
        }
        return ScreenRules()
    }()

    /// The rules answered by the library at `url`; nil when it does not open or is not ABI v1.
    /// The library stays loaded for the life of the process.
    public static func library(at url: URL) -> ScreenRules? {
        guard let library = RulesLibrary(path: url.path) else { return nil }
        return ScreenRules { operation, data in library.call(operation, data) }
    }
}

/// The two symbols of cmux_rd_screen.h.
private struct RulesLibrary: Sendable {
    typealias Version = @convention(c) () -> UInt32
    typealias JSON = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?, Int,
                                     UnsafeMutablePointer<Int>?) -> Int32
    static let ok: Int32 = 0
    static let errBuffer: Int32 = -3

    /// `cmux_rd_screen_json`'s address, kept as an integer so the struct is plainly Sendable (the
    /// library never unloads, and the function is safe to call from any thread).
    let address: UInt

    init?(path: String) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let version = dlsym(handle, "cmux_rd_screen_abi_version"), let json = dlsym(handle, "cmux_rd_screen_json"),
              unsafeBitCast(version, to: Version.self)() == 1 else {
            dlclose(handle)
            return nil
        }
        self.address = UInt(bitPattern: json)
    }

    /// One `cmux_rd_screen_json` call, retried once at the size it asks for.
    func call(_ operation: String, _ data: Data) -> Data? {
        let json = unsafeBitCast(address, to: JSON.self)
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code = data.withUnsafeBytes { request in
                operation.withCString { name in
                    output.withUnsafeMutableBufferPointer { buffer in
                        json(request.bindMemory(to: UInt8.self).baseAddress, data.count, name, buffer.baseAddress, buffer.count, &length)
                    }
                }
            }
            if code == Self.errBuffer, length > capacity {
                capacity = length
                continue
            }
            guard code == Self.ok, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}
