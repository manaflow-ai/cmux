import Darwin
import OwlBrowserCore

final class OwlChromiumRuntimeEntrypoints {
    private typealias InitializeFunction = @convention(c) () -> Int32

    private let initializeFunction: InitializeFunction

    init(libraryHandle: UnsafeMutableRawPointer) throws {
        self.initializeFunction = try Self.loadSymbol(
            "OwlFreshMojoRuntimeInitialize",
            from: libraryHandle,
            as: InitializeFunction.self
        )
    }

    func initialize() throws {
        let status = initializeFunction()
        guard status == 0 else {
            throw OwlBrowserError.bridge("OwlFreshMojoRuntimeInitialize failed with status \(status)")
        }
    }

    private static func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw OwlBrowserError.bridge("missing Chromium runtime symbol \(name)")
        }
        return unsafeBitCast(symbol, to: type)
    }
}
