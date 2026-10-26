import Foundation

/// Why a CmuxNextWireGen run failed; the build log shows `description`.
enum WireGenError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case unwritable(path: String, reason: String)
    /// A schema the method table cannot encode, with its JSON path.
    case methodTable(MethodTableSchemaError)

    var description: String {
        switch self {
        case .usage(let detail):
            "\(detail)\nusage: CmuxNextWireGen --sdk-schema PATH --resource-operations PATH [--identity-output PATH] "
                + "[--method-table-output PATH] [--event-output PATH [--event-import MODULE]] (at least one output)"
        case .unreadable(let path, let reason): "\(path): cannot read: \(reason)"
        case .malformed(let path, let reason): "\(path): not a schema file: \(reason)"
        case .unwritable(let path, let reason): "\(path): cannot write: \(reason)"
        case .methodTable(let error): "\(error)"
        }
    }
}

/// The command line: every option at most once, each followed by its value. The two schemas are
/// required, and at least one output; a run writes only the outputs it is given.
struct WireGenArguments {
    static let flags = [
        "--sdk-schema", "--resource-operations", "--identity-output", "--method-table-output", "--event-output",
        "--event-import",
    ]

    let sdkSchema: URL
    let resourceOperations: URL
    /// Where `WireSchemaIdentity.built` goes (IdentityEmitter).
    let identityOutput: URL?
    /// Where `MethodTable.schema` goes (TableEmitter).
    let methodTableOutput: URL?
    /// Where `DaemonWireEvent` goes (EventEmitter).
    let eventOutput: URL?
    /// The module `DaemonWireEvent` imports `WireEventSet` from when it is built outside CmuxNextIPC
    /// (CmuxNextIPCTests builds the fixture schema's set).
    let eventImport: String?

    init(_ argv: [String]) throws(WireGenError) {
        var values: [String: String] = [:]
        var iterator = argv.makeIterator()
        while let flag = iterator.next() {
            guard Self.flags.contains(flag) else { throw WireGenError.usage("unknown argument \(flag)") }
            guard let value = iterator.next() else { throw WireGenError.usage("\(flag) needs a value") }
            guard values.updateValue(value, forKey: flag) == nil else {
                throw WireGenError.usage("\(flag) given twice")
            }
        }
        sdkSchema = try Self.path("--sdk-schema", in: values)
        resourceOperations = try Self.path("--resource-operations", in: values)
        identityOutput = values["--identity-output"].map { URL(fileURLWithPath: $0) }
        methodTableOutput = values["--method-table-output"].map { URL(fileURLWithPath: $0) }
        eventOutput = values["--event-output"].map { URL(fileURLWithPath: $0) }
        eventImport = values["--event-import"]
        guard identityOutput != nil || methodTableOutput != nil || eventOutput != nil else {
            throw WireGenError.usage("no output: give --identity-output, --method-table-output or --event-output")
        }
        guard eventImport == nil || eventOutput != nil else {
            throw WireGenError.usage("--event-import needs --event-output")
        }
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
