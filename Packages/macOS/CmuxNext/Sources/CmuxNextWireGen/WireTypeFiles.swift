import Foundation

// The files TypeEmitter writes: the fixed support files, then one
// file per named type the `clients: macos` commands reach. CmuxNextWireGenPlugin
// compiles this same source (its Plugins/CmuxNextWireGenPlugin/WireTypeFiles.swift
// is a symlink to this file) to declare the build command's outputs, so the files
// the build expects and the files the tool writes come from one rule.
// Foundation only: the plugin links nothing else.

/// Why sdk-schema.json gives no valid list of wire type files.
struct WireTypeFilesError: Error, Equatable, CustomStringConvertible {
    /// A JSON path into sdk-schema.json.
    let path: String
    let message: String

    var description: String { "sdk-schema.json: \(path): \(message)" }
}

/// The output file names of TypeEmitter for one sdk-schema.json.
struct WireTypeFiles: Equatable {
    /// The files every schema gets, in output order: the typed ids, then the JSON value and decoding helpers.
    static let supportFileNames = ["WireSupport+Handles.swift", "WireSupport+StringIDs.swift", "WireSupport+JSON.swift"]
    static let client = "macos"

    /// The named types the client's commands reach, sorted.
    let typeNames: [String]

    /// Every output file, in the order TypeEmitter.files() returns them.
    var fileNames: [String] { Self.supportFileNames + typeNames.map(Self.fileName(type:)) }

    static func fileName(type: String) -> String { "WireTypes+\(type).swift" }

    /// Validates and sorts `names`: each must be a Swift identifier, and no two may
    /// differ only in case (they would be one file on a case-insensitive disk).
    init(typeNames names: some Sequence<String>) throws(WireTypeFilesError) {
        let sorted = Set(names).sorted()
        var folded: [String: String] = [:]
        for name in sorted {
            guard Self.isIdentifier(name) else {
                throw WireTypeFilesError(path: "$.types.\(name)", message: "a type name must be an ASCII identifier")
            }
            if let other = folded.updateValue(name, forKey: name.lowercased()) {
                throw WireTypeFilesError(path: "$.types.\(name)", message: "differs from \(other) only in case")
            }
        }
        typeNames = sorted
    }

    /// Reads the commands of ``client`` and every named type they reach, the way
    /// TypeSchemaParser does: a command without `clients` serves every client.
    init(sdkSchema: Data) throws {
        let document = try JSONSerialization.jsonObject(with: sdkSchema)
        guard let root = document as? [String: Any], let commands = root["commands"] as? [String: Any] else {
            throw WireTypeFilesError(path: "$.commands", message: "must be an object")
        }
        let types = root["types"] as? [String: Any] ?? [:]
        var pending: [String] = []
        for case let command as [String: Any] in commands.values {
            if let clients = command["clients"] as? [String], !clients.contains(Self.client) { continue }
            pending += Self.refs(in: command["request"] as Any) + Self.refs(in: command["result"] as Any)
        }
        var reached = Set<String>()
        while let name = pending.popLast() {
            guard reached.insert(name).inserted else { continue }
            pending += Self.refs(in: types[name] as Any)
        }
        try self.init(typeNames: reached)
    }

    /// Every `{"kind": "ref", "name": ...}` inside `node`.
    private static func refs(in node: Any) -> [String] {
        if let object = node as? [String: Any] {
            if object["kind"] as? String == "ref", let name = object["name"] as? String { return [name] }
            return object.values.flatMap(refs(in:))
        }
        if let array = node as? [Any] { return array.flatMap(refs(in:)) }
        return []
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && $0.properties.isAlphabetic) || ("0"..."9").contains($0) }
    }
}
