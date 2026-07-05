import Foundation

struct ParakeetModelDownloadFile: Equatable, Sendable {
    let path: String
    let size: Int64

    var pathComponents: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func files(
        fromHuggingFaceTreeJSON data: Data,
        requiredFiles: ParakeetRequiredFileSet = ParakeetModelDescriptor.parakeetV3Int8.requiredFiles
    ) throws -> [ParakeetModelDownloadFile] {
        let entries: [HuggingFaceTreeEntry]
        do {
            entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data)
        } catch {
            throw ParakeetDownloadError.invalidFileList
        }

        var filesByPath: [String: ParakeetModelDownloadFile] = [:]
        for entry in entries where entry.type == "file" && requiredFiles.contains(entry.path) {
            guard let size = entry.size else {
                throw ParakeetDownloadError.missingFileSize(path: entry.path)
            }
            filesByPath[entry.path] = ParakeetModelDownloadFile(path: entry.path, size: Int64(size))
        }

        let files = filesByPath.values.sorted { $0.path < $1.path }
        guard !files.isEmpty else {
            throw ParakeetDownloadError.emptyFileList
        }
        return files
    }

    static func totalBytes(in files: [ParakeetModelDownloadFile]) -> Int64 {
        files.reduce(0) { total, file in
            total + max(file.size, 0)
        }
    }

    func destination(in directory: URL) -> URL {
        pathComponents.reduce(directory) { url, component in
            url.appendingPathComponent(component)
        }
    }

    func existingCompleteByteCount(in directory: URL, fileManager: FileManager = .default) throws -> Int64? {
        let url = destination(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        return byteCount == size ? size : nil
    }
}

private struct HuggingFaceTreeEntry: Decodable {
    let path: String
    let type: String
    let size: Int?
}
