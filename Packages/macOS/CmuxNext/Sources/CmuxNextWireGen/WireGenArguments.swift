import Foundation

/// Why a CmuxNextWireGen run failed; the build log shows `description`.
enum WireGenError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case unwritable(path: String, reason: String)

    var description: String {
        switch self {
        case .usage(let detail):
            "\(detail)\nusage: CmuxNextWireGen --sdk-schema PATH --resource-operations PATH --identity-output PATH"
        case .unreadable(let path, let reason): "\(path): cannot read: \(reason)"
        case .malformed(let path, let reason): "\(path): not a schema file: \(reason)"
        case .unwritable(let path, let reason): "\(path): cannot write: \(reason)"
        }
    }
}

/// The command line: every option exactly once, each followed by a path.
struct WireGenArguments {
    static let flags = ["--sdk-schema", "--resource-operations", "--identity-output"]

    let sdkSchema: URL
    let resourceOperations: URL
    let identityOutput: URL

    init(_ argv: [String]) throws(WireGenError) {
        var values: [String: String] = [:]
        var iterator = argv.makeIterator()
        while let flag = iterator.next() {
            guard Self.flags.contains(flag) else { throw WireGenError.usage("unknown argument \(flag)") }
            guard let value = iterator.next() else { throw WireGenError.usage("\(flag) needs a path") }
            guard values.updateValue(value, forKey: flag) == nil else {
                throw WireGenError.usage("\(flag) given twice")
            }
        }
        sdkSchema = try Self.path("--sdk-schema", in: values)
        resourceOperations = try Self.path("--resource-operations", in: values)
        identityOutput = try Self.path("--identity-output", in: values)
    }

    private static func path(_ flag: String, in values: [String: String]) throws(WireGenError) -> URL {
        guard let value = values[flag] else { throw WireGenError.usage("missing \(flag)") }
        return URL(fileURLWithPath: value)
    }
}

/// One output file in the plugin work directory (the build system makes that directory).
struct GeneratedFile {
    let url: URL

    /// Writes `text` atomically, so a build that stops mid-write never compiles half a file.
    func write(_ text: String) throws(WireGenError) {
        do {
            // blocking-allow: host build tool, not the app; no app thread to block.
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw WireGenError.unwritable(path: url.path(percentEncoded: false), reason: "\(error)")
        }
    }
}
