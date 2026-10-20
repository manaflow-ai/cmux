internal import Darwin
internal import Foundation

/// Computes bounded in-process metadata for one untracked file.
struct WorkspaceUntrackedFileInspector: Sendable {
    static let maximumReadByteCount = 10 * 1024 * 1024
    static let maximumAggregateReadByteCount = 64 * 1024 * 1024
    static let maximumAggregateClassificationByteCount = 4 * 1024 * 1024
    static let binaryScanByteCount = 8 * 1024
    private static let readChunkByteCount = 64 * 1024

    private struct FileInspection {
        let file: WorkspaceChangedFile
        let readByteCount: Int
    }

    private let perFileReadByteCount: Int
    private let aggregateReadByteCount: Int
    private let aggregateClassificationByteCount: Int
    private let regularFileOpener = WorkspaceChangesRegularFileOpener()

    init(
        perFileReadByteCount: Int = Self.maximumReadByteCount,
        aggregateReadByteCount: Int = Self.maximumAggregateReadByteCount,
        aggregateClassificationByteCount: Int = Self.maximumAggregateClassificationByteCount
    ) {
        self.perFileReadByteCount = max(0, perFileReadByteCount)
        self.aggregateReadByteCount = max(0, aggregateReadByteCount)
        self.aggregateClassificationByteCount = max(0, aggregateClassificationByteCount)
    }

    func inspect(path: String, repoRoot: String) -> WorkspaceChangedFile? {
        inspect(
            path: path,
            repoRoot: repoRoot,
            maximumReadByteCount: perFileReadByteCount
        )?.file
    }

    func inspect(paths: [String], repoRoot: String) -> [WorkspaceChangedFile]? {
        var remainingByteCount = aggregateReadByteCount
        var remainingClassificationByteCount = aggregateClassificationByteCount
        var files: [WorkspaceChangedFile] = []
        files.reserveCapacity(paths.count)

        for path in paths {
            guard !WorkspaceChangesCancellationSignal.isCurrentCancelled else {
                files.append(zeroAdditionFile(
                    path: path,
                    isBinary: true,
                    isApproximate: true
                ))
                continue
            }
            if remainingByteCount > 0 {
                guard let inspection = inspect(
                    path: path,
                    repoRoot: repoRoot,
                    maximumReadByteCount: min(perFileReadByteCount, remainingByteCount)
                ) else {
                    files.append(zeroAdditionFile(
                        path: path,
                        isBinary: true,
                        isApproximate: true
                    ))
                    continue
                }
                files.append(inspection.file)
                remainingByteCount -= inspection.readByteCount
                continue
            }

            let probeByteCount = min(
                Self.binaryScanByteCount,
                remainingClassificationByteCount
            )
            guard probeByteCount > 0,
                  let classification = inspect(
                      path: path,
                      repoRoot: repoRoot,
                      maximumReadByteCount: probeByteCount
                  ) else {
                files.append(zeroAdditionFile(
                    path: path,
                    isBinary: true,
                    isApproximate: true
                ))
                continue
            }
            remainingClassificationByteCount -= classification.readByteCount
            files.append(zeroAdditionFile(
                path: path,
                isBinary: classification.file.isBinary,
                isApproximate: !classification.file.isBinary
            ))
        }
        return files
    }

    private func inspect(
        path: String,
        repoRoot: String,
        maximumReadByteCount: Int
    ) -> FileInspection? {
        guard let openedFile = try? regularFileOpener.open(
            repoRoot: repoRoot,
            relativePath: path
        ) else { return nil }
        let descriptor = openedFile.descriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            Darwin.close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        let fileSize = max(Int64(openedFile.metadata.st_size), 0)
        var readByteCount = 0
        var newlineCount = 0
        var lastByte: UInt8?
        var isBinary = false
        var reachedEOF = false

        while readByteCount < maximumReadByteCount {
            guard !WorkspaceChangesCancellationSignal.isCurrentCancelled else { break }
            let remaining = maximumReadByteCount - readByteCount
            let chunk: Data
            do {
                chunk = try handle.read(
                    upToCount: min(Self.readChunkByteCount, remaining)
                ) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else {
                reachedEOF = true
                break
            }
            let binaryRemaining = max(0, Self.binaryScanByteCount - readByteCount)
            readByteCount += chunk.count
            if binaryRemaining > 0,
               chunk.prefix(binaryRemaining).contains(0) {
                isBinary = true
                break
            }
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            lastByte = chunk.last
        }

        if Int64(readByteCount) >= fileSize {
            reachedEOF = true
        }
        let additions: Int
        if isBinary {
            additions = 0
        } else {
            additions = newlineCount + (reachedEOF && readByteCount > 0 && lastByte != 0x0A ? 1 : 0)
        }
        return FileInspection(
            file: WorkspaceChangedFile(
                path: path,
                oldPath: nil,
                status: .untracked,
                additions: additions,
                deletions: 0,
                isBinary: isBinary,
                isApproximate: !isBinary && !reachedEOF
            ),
            readByteCount: readByteCount
        )
    }

    private func zeroAdditionFile(
        path: String,
        isBinary: Bool,
        isApproximate: Bool
    ) -> WorkspaceChangedFile {
        WorkspaceChangedFile(
            path: path,
            oldPath: nil,
            status: .untracked,
            additions: 0,
            deletions: 0,
            isBinary: isBinary,
            isApproximate: isApproximate
        )
    }
}
