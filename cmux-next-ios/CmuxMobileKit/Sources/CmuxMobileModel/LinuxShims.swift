#if !canImport(OSLog)
// No unified log off Apple platforms (the Linux test build, swift-linux-packages.yml): the module's
// `Logger` calls compile against this and write nothing. Apple builds use OSLog's Logger.
struct Logger: Sendable {
    init(subsystem: String, category: String) {}
    func debug(_ message: LogMessage) {}
    func info(_ message: LogMessage) {}
    func notice(_ message: LogMessage) {}
    func warning(_ message: LogMessage) {}
    func error(_ message: LogMessage) {}
    func fault(_ message: LogMessage) {}
}

struct LogMessage: ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {}
    init(stringInterpolation: Interpolation) {}

    struct Interpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) {}
        mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: LogPrivacy = .private) {}
    }
}

enum LogPrivacy { case `public`, `private` }
#endif

#if !canImport(Darwin)
import Foundation

// No String Catalog lookup off Apple platforms (the Linux test build): `String(localized:)` is the
// English source text, as an Apple build with no translation for the key gives.
extension String {
    init(localized key: String, defaultValue: String? = nil, table: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {
        self = defaultValue ?? key
    }
}
#endif
