import Foundation

/// Why a CmuxNextWireGen run failed; the build log shows `description`.
enum WireGenError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case unwritable(path: String, reason: String)
    /// A schema the method table cannot encode, with its JSON path.
    case methodTable(MethodTableSchemaError)
    /// An operation catalog the v2 bindings cannot spell, with its JSON path (ResourceEmitter).
    case resourceOperations(ResourceEmitterError)
    /// A schema type the Swift wire types cannot express, with its JSON path.
    case types(TypeSchemaError)

    var description: String {
        switch self {
        case .usage(let detail):
            "\(detail)\nusage: CmuxNextWireGen --sdk-schema PATH --resource-operations PATH [--identity-output PATH] "
                + "[--method-table-output PATH] [--event-output PATH [--event-import MODULE]] "
                + "[--resource-output-dir DIR --resource-operation-names NAME,...] [--types-output-dir DIR] "
                + "(at least one output)"
        case .unreadable(let path, let reason): "\(path): cannot read: \(reason)"
        case .malformed(let path, let reason): "\(path): not a schema file: \(reason)"
        case .unwritable(let path, let reason): "\(path): cannot write: \(reason)"
        case .methodTable(let error): "\(error)"
        case .resourceOperations(let error): "\(error)"
        case .types(let error): "\(error)"
        }
    }
}

/// The command line: every option at most once, each followed by its value. The two schemas are
/// required, and at least one output; a run writes only the outputs it is given.
struct WireGenArguments {
    static let flags = [
        "--sdk-schema", "--resource-operations", "--identity-output", "--method-table-output", "--event-output",
        "--event-import", "--resource-output-dir", "--resource-operation-names", "--types-output-dir",
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
    /// (CmuxNextIPCTestSupport builds the fixture schema's set).
    let eventImport: String?
    /// Where the `cmux.protocol/2` requests go, one file per operation family (ResourceEmitter).
    let resourceOutputDirectory: URL?
    /// The operations those requests are for, comma-separated on the command line.
    let resourceOperationNames: [String]
    /// The directory TypeEmitter writes its support files and per-type files into.
    let typesOutputDirectory: URL?

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
        resourceOutputDirectory = values["--resource-output-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        typesOutputDirectory = values["--types-output-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        resourceOperationNames = values["--resource-operation-names"].map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } ?? []
        guard identityOutput != nil || methodTableOutput != nil || eventOutput != nil || resourceOutputDirectory != nil
            || typesOutputDirectory != nil
        else {
            throw WireGenError.usage(
                "no output: give --identity-output, --method-table-output, --event-output, --resource-output-dir "
                    + "or --types-output-dir")
        }
        guard (resourceOutputDirectory == nil) == (values["--resource-operation-names"] == nil) else {
            throw WireGenError.usage("--resource-output-dir and --resource-operation-names go together")
        }
        guard !resourceOperationNames.contains(where: \.isEmpty) else {
            throw WireGenError.usage("--resource-operation-names has an empty name")
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

    /// Writes `text` atomically, so a build that stops mid-write never compiles half a file: the bytes
    /// go to a new temporary file in the same directory, which rename(2) then puts in place. A failure
    /// removes the temporary file.
    ///
    /// Not `Data.write(to:options: .atomic)`: in a sandboxed process (SwiftPM runs build-tool commands
    /// in a sandbox) Foundation first asks FileManager for an item-replacement directory, a coreservicesd
    /// look-up that blocked forever in a non-GUI fleet session (swift-build waited 95 min, 2026-10-28).
    func write(_ text: String) throws(WireGenError) {
        let path = url.path(percentEncoded: false)
        let directory = (path as NSString).deletingLastPathComponent
        var template = Array("\(directory)/.\(url.lastPathComponent).XXXXXX".utf8CString)
        let descriptor = unsafe template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = unsafe buffer.baseAddress else {
                errno = EINVAL
                return -1
            }
            return unsafe mkstemp(base)
        }
        guard descriptor >= 0 else {
            throw WireGenError.unwritable(path: path, reason: Self.reason("create a temporary file in", directory, errno))
        }
        // mkstemp replaced the Xs in place; the last element is the terminating NUL.
        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var problem: String?
        do {
            // blocking-allow: host build tool, not the app; no app thread to block.
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: Data(text.utf8))
        } catch {
            problem = "write \(temporary): \(error)"
        }
        // Each failed call's errno is read before anything else runs: `reason` gets it as an argument
        // and builds its text (which allocates, and can set errno) only after.
        // mkstemp makes the file 0600; a generated source is readable as any other file is.
        if problem == nil, fchmod(descriptor, 0o644) != 0 { problem = Self.reason("chmod", temporary, errno) }
        if close(descriptor) != 0, problem == nil { problem = Self.reason("close", temporary, errno) }
        // blocking-allow: host build tool, not the app; the rename that makes the write atomic.
        if problem == nil, unsafe rename(temporary, path) != 0 { problem = Self.reason("rename", temporary, errno) }
        if let problem {
            // blocking-allow: host build tool, not the app; removes the temporary file of a failed write.
            unsafe unlink(temporary)
            throw WireGenError.unwritable(path: path, reason: problem)
        }
    }

    private static func reason(_ step: StaticString, _ path: String, _ code: Int32) -> String {
        "\(step) \(path): \(unsafe String(cString: strerror(code)))"
    }
}
