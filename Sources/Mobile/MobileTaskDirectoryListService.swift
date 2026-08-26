import Darwin
import Foundation

/// Lists one Mac directory level at a time so mobile can traverse every
/// accessible path without an exhaustive filesystem index.
actor MobileTaskDirectoryListService {
    static let maximumPageSize = 100

    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = (homeDirectory ?? fileManager.homeDirectoryForCurrentUser)
            .standardizedFileURL
    }

    func list(
        path rawPath: String,
        offset requestedOffset: Int,
        limit: Int
    ) throws -> MobileTaskDirectoryListPage {
        guard requestedOffset >= 0, (1...Self.maximumPageSize).contains(limit) else {
            throw MobileTaskDirectoryListServiceError.invalidRequest
        }
        try Task.checkCancellation()
        let directory = try resolvedDirectoryURL(rawPath)
        let childURLs: [URL]
        do {
            childURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isHiddenKey,
                    .isPackageKey,
                ],
                options: []
            )
        } catch {
            throw mappedListingError(error)
        }

        var entries: [MobileTaskDirectoryListItem] = []
        entries.reserveCapacity(childURLs.count)
        for childURL in childURLs {
            try Task.checkCancellation()
            if let item = directoryItem(at: childURL) {
                entries.append(item)
            }
        }
        entries.sort(by: Self.precedes)
        try Task.checkCancellation()
        let offset = min(requestedOffset, entries.count)
        let end = min(offset + limit, entries.count)
        let pageEntries = Array(entries[offset..<end])
        return MobileTaskDirectoryListPage(
            currentPath: directory.path,
            parentPath: Self.parentPath(of: directory.path),
            entries: pageEntries,
            offset: offset,
            limit: limit,
            totalCount: entries.count,
            nextOffset: end < entries.count ? end : nil
        )
    }

    private func resolvedDirectoryURL(_ rawPath: String) throws -> URL {
        guard Self.isValidRequestPath(rawPath) else {
            throw MobileTaskDirectoryListServiceError.invalidPath
        }
        let expandedPath: String
        if rawPath == "~" {
            expandedPath = homeDirectory.path
        } else if rawPath.hasPrefix("~/") {
            expandedPath = homeDirectory
                .appendingPathComponent(String(rawPath.dropFirst(2)), isDirectory: true)
                .path
        } else {
            expandedPath = rawPath
        }

        let directory = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw MobileTaskDirectoryListServiceError.notFound
        }
        guard isDirectory.boolValue else {
            throw MobileTaskDirectoryListServiceError.notDirectory
        }
        guard fileManager.isReadableFile(atPath: directory.path) else {
            throw MobileTaskDirectoryListServiceError.unreadable
        }
        return directory
    }

    private func directoryItem(at url: URL) -> MobileTaskDirectoryListItem? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let resourceValues = try? url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let name = url.lastPathComponent
        return MobileTaskDirectoryListItem(
            name: name,
            path: url.standardizedFileURL.path,
            isHidden: (resourceValues?.isHidden ?? false) || name.hasPrefix("."),
            isPackage: resourceValues?.isPackage ?? false,
            isSymbolicLink: attributes?[.type] as? FileAttributeType == .typeSymbolicLink,
            isReadable: fileManager.isReadableFile(atPath: url.path)
        )
    }

    private func mappedListingError(_ error: any Error) -> MobileTaskDirectoryListServiceError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError:
                return .notFound
            case NSFileReadNoPermissionError:
                return .permissionDenied
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                return .permissionDenied
            case Int(ENOENT):
                return .notFound
            case Int(ENOTDIR):
                return .notDirectory
            default:
                break
            }
        }
        return .unreadable
    }

    private static func precedes(
        _ lhs: MobileTaskDirectoryListItem,
        _ rhs: MobileTaskDirectoryListItem
    ) -> Bool {
        MobileTaskDirectoryListItem.precedes(lhs, rhs)
    }

    private static func isValidRequestPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        return path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }

    private static func parentPath(of path: String) -> String? {
        guard path != "/" else { return nil }
        let components = (path as NSString).pathComponents
        guard components.count > 1 else { return "/" }
        return NSString.path(withComponents: Array(components.dropLast()))
    }
}
