import Foundation

/// Executes the REPL's `fs` operations inside a `BrowserReplFileSandbox`.
///
/// Every operation takes and returns JSON-compatible values so the
/// JavaScriptCore bridge can pass them as strings. Paths are checked with the
/// sandbox before touching the disk; errors carry Node error codes so the
/// runtime can build Node-compatible `Error` objects.
public struct BrowserReplFileSystem: Sendable {
    /// The sandbox that authorizes every path.
    public var sandbox: BrowserReplFileSandbox

    /// Canonical temporary directory, a second root next to the sandbox root.
    public let temporaryRoot: String

    /// - Parameter temporaryDirectory: The user's temporary directory;
    ///   `nil` uses `NSTemporaryDirectory()`.
    public init(sandbox: BrowserReplFileSandbox, temporaryDirectory: String? = nil) {
        self.sandbox = sandbox
        self.temporaryRoot = BrowserReplFileSandbox.canonicalize(
            BrowserReplFileSandbox.lexicallyNormalized(temporaryDirectory ?? NSTemporaryDirectory())
        )
    }

    /// Runs one operation. See `docs/browser-repl/driver-protocol.md` for ops.
    public func perform(_ operation: String, arguments: [String: Any]) -> Result<Any, BrowserReplFileSystemError> {
        do {
            return .success(try run(operation, arguments))
        } catch let error as BrowserReplFileSystemError {
            return .failure(error)
        } catch {
            return .failure(Self.translate(error, operation: operation, path: arguments["path"] as? String ?? ""))
        }
    }

    private func run(_ operation: String, _ arguments: [String: Any]) throws -> Any {
        let fileManager = FileManager.default
        // `fs` reaches the working directory and the temporary directory.
        let extraRoots = [temporaryRoot]
        func path(_ access: BrowserReplFileSandbox.Access, key: String = "path") throws -> String {
            guard let raw = arguments[key] as? String else {
                throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: missing '\(key)'")
            }
            return try sandbox.resolve(raw, for: access, additionalRoots: extraRoots)
        }

        switch operation {
        case "resolve":
            return try path(.read)
        case "exists":
            guard let resolved = try? path(.read) else { return false }
            return fileManager.fileExists(atPath: resolved)
        case "readFile":
            let resolved = try path(.read)
            try requireFile(resolved, operation: "open", display: arguments["path"] as? String ?? resolved)
            return try Data(contentsOf: URL(fileURLWithPath: resolved)).base64EncodedString()
        case "writeFile":
            let resolved = try path(.write)
            let data = Data(base64Encoded: arguments["base64"] as? String ?? "") ?? Data()
            let url = URL(fileURLWithPath: resolved)
            try requireParentDirectory(resolved, display: arguments["path"] as? String ?? resolved)
            if arguments["append"] as? Bool == true, fileManager.fileExists(atPath: resolved) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
            return NSNull()
        case "mkdir":
            let resolved = try path(.write)
            let recursive = arguments["recursive"] as? Bool ?? false
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) {
                if recursive, isDirectory.boolValue { return NSNull() }
                throw BrowserReplFileSystemError(
                    code: "EEXIST",
                    message: "EEXIST: file already exists, mkdir '\(arguments["path"] as? String ?? resolved)'"
                )
            }
            if !recursive {
                try requireParentDirectory(resolved, display: arguments["path"] as? String ?? resolved)
            }
            try fileManager.createDirectory(atPath: resolved, withIntermediateDirectories: recursive)
            return NSNull()
        case "readdir":
            let resolved = try path(.read)
            return try fileManager.contentsOfDirectory(atPath: resolved).sorted().map { name -> [String: Any] in
                ["name": name, "type": Self.entryType(resolved + "/" + name)]
            }
        case "stat":
            let resolved = try path(.read)
            let attributes = try fileManager.attributesOfItem(atPath: resolved)
            let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let created = (attributes[.creationDate] as? Date) ?? modified
            return [
                "size": (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                "type": Self.entryType(resolved),
                "mtimeMs": modified.timeIntervalSince1970 * 1000,
                "birthtimeMs": created.timeIntervalSince1970 * 1000,
            ] as [String: Any]
        case "rm":
            let resolved = try path(.write)
            guard resolved != sandbox.root, resolved != temporaryRoot else {
                throw BrowserReplFileSystemError(code: "EACCES", message: "EACCES: refusing to remove the REPL working directory")
            }
            let force = arguments["force"] as? Bool ?? false
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
                if force { return NSNull() }
                throw BrowserReplFileSystemError(
                    code: "ENOENT",
                    message: "ENOENT: no such file or directory, rm '\(arguments["path"] as? String ?? resolved)'"
                )
            }
            if isDirectory.boolValue, arguments["recursive"] as? Bool != true {
                let contents = try fileManager.contentsOfDirectory(atPath: resolved)
                if !contents.isEmpty {
                    throw BrowserReplFileSystemError(
                        code: "ENOTEMPTY",
                        message: "ENOTEMPTY: directory not empty, rm '\(arguments["path"] as? String ?? resolved)'"
                    )
                }
            }
            try fileManager.removeItem(atPath: resolved)
            return NSNull()
        case "rename":
            let from = try path(.write, key: "from")
            let to = try path(.write, key: "to")
            if fileManager.fileExists(atPath: to) {
                try fileManager.removeItem(atPath: to)
            }
            try fileManager.moveItem(atPath: from, toPath: to)
            return NSNull()
        case "copyFile":
            let from = try path(.read, key: "from")
            let to = try path(.write, key: "to")
            if fileManager.fileExists(atPath: to) {
                try fileManager.removeItem(atPath: to)
            }
            try fileManager.copyItem(atPath: from, toPath: to)
            return NSNull()
        default:
            throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: unsupported fs operation '\(operation)'")
        }
    }

    private func requireFile(_ resolved: String, operation: String, display: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            throw BrowserReplFileSystemError(
                code: "ENOENT",
                message: "ENOENT: no such file or directory, \(operation) '\(display)'"
            )
        }
        if isDirectory.boolValue {
            throw BrowserReplFileSystemError(
                code: "EISDIR",
                message: "EISDIR: illegal operation on a directory, read"
            )
        }
    }

    private func requireParentDirectory(_ resolved: String, display: String) throws {
        let parent = (resolved as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrowserReplFileSystemError(
                code: "ENOENT",
                message: "ENOENT: no such file or directory, open '\(display)'"
            )
        }
    }

    static func entryType(_ path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else {
            return "other"
        }
        switch type {
        case .typeRegular: return "file"
        case .typeDirectory: return "directory"
        case .typeSymbolicLink: return "symlink"
        default: return "other"
        }
    }

    static func translate(_ error: any Error, operation: String, path: String) -> BrowserReplFileSystemError {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : (nsError.domain == NSPOSIXErrorDomain ? nsError.code : nil)
        let code: String
        switch (posix, nsError.code) {
        case (Int(ENOENT)?, _), (_, NSFileNoSuchFileError), (_, NSFileReadNoSuchFileError): code = "ENOENT"
        case (Int(EEXIST)?, _), (_, NSFileWriteFileExistsError): code = "EEXIST"
        case (Int(ENOTDIR)?, _): code = "ENOTDIR"
        case (Int(EISDIR)?, _): code = "EISDIR"
        case (Int(ENOTEMPTY)?, _): code = "ENOTEMPTY"
        case (Int(EACCES)?, _), (Int(EPERM)?, _), (_, NSFileReadNoPermissionError), (_, NSFileWriteNoPermissionError): code = "EACCES"
        default: code = "EIO"
        }
        return BrowserReplFileSystemError(code: code, message: "\(code): \(nsError.localizedDescription), \(operation) '\(path)'")
    }
}
