public import CmuxNextWakeups
public import Foundation

/// Make Alias, Delete Immediately, Compress and Expand on the real file system, on the files lane.
extension FileOperator {
    public func makeLinks(_ urls: [URL], kind: LinkKind) async throws -> [URL] {
        var made: [URL] = []
        let namer = namer
        for url in urls {
            try Task.checkCancellation()
            made.append(try await work.run(.userBlocking, mayBlock: .files) {
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
                return target
            })
        }
        return made
    }

    public func deleteImmediately(_ urls: [URL]) async throws {
        try await work.run(.userBlocking, mayBlock: .files) {
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw FileBrowserError.failed(error.localizedDescription)
                }
            }
        }
    }

    public func compress(_ urls: [URL], archiveName: String) async throws -> URL {
        guard let first = urls.first else { throw FileBrowserError.missing(URL(fileURLWithPath: "/")) }
        let folder = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : archiveName
        let namer = namer
        if urls.count == 1 {
            let (target, keepParent) = try await work.run(.userBlocking, mayBlock: .files) { () -> (URL, Bool) in
                let target = folder.appendingPathComponent(namer.freeName(for: base + ".zip", style: .number,
                                                                          taken: Self.names(in: folder)))
                // --keepParent names the archive's top folder after a folder source;
                // for a file it would wrap the file in its containing folder.
                let keepParent = first.hasDirectoryPath || (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return (target, keepParent)
            }
            try await ditto(["-c", "-k", "--sequesterRsrc"] + (keepParent ? ["--keepParent"] : []) + [first.path, target.path])
            return target
        }
        // ditto archives one source: clone the items (metadata-only on APFS)
        // into a staging folder on the same volume and archive its contents.
        let (target, staging) = try await work.run(.userBlocking, mayBlock: .files) { () -> (URL, URL) in
            let target = folder.appendingPathComponent(namer.freeName(for: base + ".zip", style: .number,
                                                                      taken: Self.names(in: folder)))
            let staging = try Self.stagingFolder(near: folder)
            do {
                for url in urls {
                    try Self.copy(url, to: staging.appendingPathComponent(url.lastPathComponent), progress: { _ in true })
                }
            } catch {
                Self.removeStaging(staging)
                throw error
            }
            return (target, staging)
        }
        do {
            try await ditto(["-c", "-k", "--sequesterRsrc", staging.path, target.path])
        } catch {
            work.post(.bestEffort, mayBlock: .files) { Self.removeStaging(staging) }
            throw error
        }
        work.post(.bestEffort, mayBlock: .files) { Self.removeStaging(staging) }
        return target
    }

    public func expand(_ archive: URL) async throws -> URL {
        let folder = archive.deletingLastPathComponent()
        let staging = try await work.run(.userBlocking, mayBlock: .files) { try Self.stagingFolder(near: folder) }
        do {
            try await ditto(["-x", "-k", archive.path, staging.path])
        } catch {
            work.post(.bestEffort, mayBlock: .files) { Self.removeStaging(staging) }
            throw error
        }
        let namer = namer
        return try await work.run(.userBlocking, mayBlock: .files) {
            defer { Self.removeStaging(staging) }
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
    }

    /// Removes a staging folder; on the files lane only.
    static func removeStaging(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
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

    /// Runs `/usr/bin/ditto` (the tool Finder's Compress uses) and awaits its exit without holding a thread.
    func ditto(_ arguments: [String]) async throws {
        let outcome: ProcessOutcome
        do {
            outcome = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/ditto"), arguments,
                                                                  errorOutput: .separate, onCancel: .finish))
        } catch let failure as ProcessFailure {
            throw FileBrowserError.failed(String(describing: failure))
        }
        guard outcome.succeeded else {
            let message = String(decoding: outcome.errorOutput, as: UTF8.self)
            throw FileBrowserError.failed(message.isEmpty ? "ditto exited with \(outcome.status)" : message)
        }
    }
}
