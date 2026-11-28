#if !canImport(OSLog)
import Foundation

/// The `os.Logger` surface this package uses, for platforms without Apple's OSLog module
/// (the Linux package tests). Lines go to standard error.
enum OSLogPrivacy {
    case `public`
    case `private`
}

extension DefaultStringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy) {
        switch privacy {
        case .public: appendInterpolation(value)
        case .private: appendLiteral("<private>")
        }
    }
}

struct Logger: Sendable {
    private let prefix: String

    init(subsystem: String, category: String) {
        prefix = "[\(subsystem):\(category)]"
    }

    func info(_ message: String) { emit("info", message) }
    func error(_ message: String) { emit("error", message) }

    private func emit(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("\(prefix) \(level): \(message)\n".utf8))
    }
}
#endif
