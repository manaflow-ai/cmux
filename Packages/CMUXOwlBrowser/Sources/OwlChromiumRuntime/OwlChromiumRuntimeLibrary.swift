import Darwin
import Foundation
import OwlBrowserCore
import OwlMojoSystem

public final class OwlChromiumRuntimeLibrary {
    public let path: String
    public let mojoSystem: DynamicMojoSystem
    public let linkMode = "dynamic-chromium-mojo-core-dylib"

    private let handle: UnsafeMutableRawPointer
    private let entrypoints: OwlChromiumRuntimeEntrypoints

    public init(path: String) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let handle = dlopen(expandedPath, RTLD_NOW | RTLD_LOCAL) else {
            throw OwlBrowserError.bridge("dlopen failed for \(expandedPath): \(Self.dlerrorString())")
        }

        do {
            self.mojoSystem = try DynamicMojoSystem(libraryHandle: handle)
            self.entrypoints = try OwlChromiumRuntimeEntrypoints(libraryHandle: handle)
            self.handle = handle
            self.path = expandedPath
        } catch {
            dlclose(handle)
            throw OwlBrowserError.bridge("failed to load Chromium runtime symbols from \(expandedPath): \(error)")
        }
    }

    deinit {
        dlclose(handle)
    }

    public func initialize() throws {
        try entrypoints.initialize()
    }

    private static func dlerrorString() -> String {
        guard let error = dlerror() else {
            return "unknown dynamic loader error"
        }
        return String(cString: error)
    }
}
