public import Foundation

/// Make Alias, Delete Immediately, Compress and Expand on the real file system.
extension FileOperator {
    @concurrent
    public func makeLinks(_ urls: [URL], kind: LinkKind) async throws -> [URL] {
        var made: [URL] = []
        for url in urls {
            try Task.checkCancellation()
            let folder = url.deletingLastPathComponent()
            let target = folder.appendingPathComponent(namer.freeName(for: url.lastPathComponent, style: .alias,
                                                                      taken: Self.names(in: folder)))
            do {
                switch kind {
                case .symlink:
                    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: url.path)
                case .alias:
                    let bookmark = try url.bookmarkData(options: .suitableForBookmarkFile)
                    try URL.writeBookmarkData(bookmark, to: target)
                }
            } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
            made.append(target)
        }
        return made
    }

    @concurrent
    public func deleteImmediately(_ urls: [URL]) async throws {
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw FileBrowserError.failed(error.localizedDescription)
            }
        }
    }

    @concurrent
    public func compress(_ urls: [URL], archiveName: String) async throws -> URL {
        guard let first = urls.first else { throw FileBrowserError.missing(URL(fileURLWithPath: "/")) }
        let folder = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : archiveName
        let target = folder.appendingPathComponent(namer.freeName(for: base + ".zip", style: .number,
                                                                  taken: Self.names(in: folder)))
        if urls.count == 1 {
            // --keepParent names the archive's top folder after a folder source;
            // for a file it would wrap the file in its containing folder.
            let keepParent = first.hasDirectoryPath || (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            try await Self.ditto(["-c", "-k", "--sequesterRsrc"] + (keepParent ? ["--keepParent"] : []) + [first.path, target.path])
            return target
        }
        // ditto archives one source: clone the items (metadata-only on APFS)
        // into a staging folder on the same volume and archive its contents.
        let staging = try Self.stagingFolder(near: folder)
        defer { try? FileManager.default.removeItem(at: staging) }
        for url in urls {
            try Self.copy(url, to: staging.appendingPathComponent(url.lastPathComponent), progress: { _ in true })
        }
        try await Self.ditto(["-c", "-k", "--sequesterRsrc", staging.path, target.path])
        return target
    }

    @concurrent
    public func expand(_ archive: URL) async throws -> URL {
        let folder = archive.deletingLastPathComponent()
        let staging = try Self.stagingFolder(near: folder)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Self.ditto(["-x", "-k", archive.path, staging.path])
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [])
            .filter { $0 != "__MACOSX" }
        let taken = Self.names(in: folder)
        let source: URL
        let name: String
        if items.count == 1 {
            source = staging.appendingPathComponent(items[0])
            name = namer.freeName(for: items[0], style: .number, taken: taken)
        } else {
            source = staging
            name = namer.freeName(for: (archive.lastPathComponent as NSString).deletingPathExtension, style: .number, taken: taken)
        }
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
        return target
    }

    /// A new empty folder on the same volume as `folder`, for work that ends in a rename.
    static func stagingFolder(near folder: URL) throws -> URL {
        do {
            let base = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: folder, create: true)
            let staging = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            return staging
        } catch {
            throw FileBrowserError.failed(error.localizedDescription)
        }
    }

    /// Runs `/usr/bin/ditto` (the tool Finder's Compress uses) and waits for it.
    @concurrent
    static func ditto(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            // The handler runs once, after exit; it is the only resume after a successful run().
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: FileBrowserError.failed(error.localizedDescription))
            }
        }
        guard status == 0 else {
            // concurrency-allow: @concurrent, after ditto exited; ditto starts no children, so EOF is immediate.
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FileBrowserError.failed(message.isEmpty ? "ditto exited with \(status)" : message)
        }
    }
}
