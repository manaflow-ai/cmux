import Foundation

/// Read-only inventory of scratch trees explicitly owned by cmux.
///
/// The inventory has no cleanup side effects. It recognizes only the canonical
/// cmux root and session directories carrying a regular `.cmux-owned` marker;
/// unmarked paths and symlinks are ignored.
// lint:allow namespace-type — static read-only inventory API keeps traversal policy centralized.
public enum AgentArtifactInventory {
    public static let ownershipMarkerName = ".cmux-owned"
    public static let ownershipMarkerPrefix = "cmux-agent-artifact-v1"

    public struct Limits: Sendable, Equatable {
        public var maximumRuns: Int
        public var maximumFilesPerRun: Int
        public var maximumBytesPerRun: Int64
        public var maximumVisitedEntriesPerRun: Int

        public init(
            maximumRuns: Int = 1_000,
            maximumFilesPerRun: Int = 10_000,
            maximumBytesPerRun: Int64 = 1_073_741_824,
            maximumVisitedEntriesPerRun: Int = 100_000
        ) {
            self.maximumRuns = max(0, maximumRuns)
            self.maximumFilesPerRun = max(0, maximumFilesPerRun)
            self.maximumBytesPerRun = max(0, maximumBytesPerRun)
            self.maximumVisitedEntriesPerRun = max(0, maximumVisitedEntriesPerRun)
        }
    }

    public struct Entry: Sendable, Equatable {
        public let provider: String
        public let sessionID: String
        public let root: URL
        public let modifiedAt: Date?
        public let bytes: Int64
        public let fileCount: Int
        public let scanTruncated: Bool
        public let unavailableReason: String?

        public init(
            provider: String,
            sessionID: String,
            root: URL,
            modifiedAt: Date?,
            bytes: Int64,
            fileCount: Int,
            scanTruncated: Bool,
            unavailableReason: String?
        ) {
            self.provider = provider
            self.sessionID = sessionID
            self.root = root
            self.modifiedAt = modifiedAt
            self.bytes = bytes
            self.fileCount = fileCount
            self.scanTruncated = scanTruncated
            self.unavailableReason = unavailableReason
        }
    }

    public struct Report: Sendable, Equatable {
        public let canonicalRoot: URL
        public let entries: [Entry]

        public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
        public var totalFiles: Int { entries.reduce(0) { $0 + $1.fileCount } }

        public init(canonicalRoot: URL, entries: [Entry]) {
            self.canonicalRoot = canonicalRoot
            self.entries = entries
        }
    }

    public static func canonicalRoot(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-artifacts", isDirectory: true)
    }

    public static func scan(
        homeDirectory: URL,
        fileManager: FileManager = .default,
        limits: Limits = Limits(),
        providerFilter: String? = nil
    ) -> Report {
        let root = canonicalRoot(homeDirectory: homeDirectory)
        guard safeCanonicalRoot(homeDirectory: homeDirectory) != nil else {
            return Report(canonicalRoot: root, entries: [])
        }
        guard isDirectory(root, fileManager: fileManager) else {
            return Report(canonicalRoot: root, entries: [])
        }

        var entries: [Entry] = []
        var inspectedRuns = 0
        let normalizedProviderFilter = providerFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for providerURL in directoryContents(root, fileManager: fileManager) {
            guard inspectedRuns < limits.maximumRuns,
                  safePathComponent(providerURL.lastPathComponent),
                  isDirectory(providerURL, fileManager: fileManager) else { continue }
            if let normalizedProviderFilter,
               providerURL.lastPathComponent.lowercased() != normalizedProviderFilter {
                continue
            }
            for sessionURL in directoryContents(providerURL, fileManager: fileManager) {
                guard inspectedRuns < limits.maximumRuns,
                      safePathComponent(sessionURL.lastPathComponent),
                      isDirectory(sessionURL, fileManager: fileManager) else { continue }
                guard isOwnedRun(sessionURL, fileManager: fileManager) else { continue }
                inspectedRuns += 1
                if let entry = inspect(
                    provider: providerURL.lastPathComponent,
                    sessionID: sessionURL.lastPathComponent,
                    root: sessionURL,
                    fileManager: fileManager,
                    limits: limits
                ) {
                    entries.append(entry)
                }
            }
        }
        return Report(canonicalRoot: root, entries: entries.sorted { $0.root.path < $1.root.path })
    }

    public static func inspect(
        provider: String,
        sessionID: String,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        limits: Limits = Limits()
    ) -> Entry? {
        guard safePathComponent(provider), safePathComponent(sessionID) else { return nil }
        guard safeCanonicalRoot(homeDirectory: homeDirectory) != nil else { return nil }
        let root = canonicalRoot(homeDirectory: homeDirectory)
            .appendingPathComponent(provider, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        guard isDirectory(root, fileManager: fileManager) else { return nil }
        return inspect(provider: provider, sessionID: sessionID, root: root, fileManager: fileManager, limits: limits)
    }

    private static func inspect(
        provider: String,
        sessionID: String,
        root: URL,
        fileManager: FileManager,
        limits: Limits
    ) -> Entry? {
        let marker = root.appendingPathComponent(ownershipMarkerName)
        guard isRegularFile(marker, fileManager: fileManager),
              (try? String(contentsOf: marker, encoding: .utf8))?.hasPrefix(ownershipMarkerPrefix) == true else {
            return nil
        }

        let modifiedAt = try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var bytes: Int64 = 0
        var fileCount = 0
        var truncated = false
        var visitedEntries = 0
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return Entry(provider: provider, sessionID: sessionID, root: root, modifiedAt: modifiedAt ?? nil, bytes: 0, fileCount: 0, scanTruncated: false, unavailableReason: nil)
        }
        while let url = enumerator.nextObject() as? URL {
            guard visitedEntries < limits.maximumVisitedEntriesPerRun else {
                truncated = true
                break
            }
            visitedEntries += 1
            if isSymbolicLink(url, fileManager: fileManager) {
                enumerator.skipDescendants()
                continue
            }
            if isDirectory(url, fileManager: fileManager) {
                continue
            }
            guard isRegularFile(url, fileManager: fileManager), url.path != marker.path else { continue }
            let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard fileCount < limits.maximumFilesPerRun,
                  fileSize <= limits.maximumBytesPerRun - bytes else {
                truncated = true
                break
            }
            fileCount += 1
            bytes += fileSize
        }
        return Entry(provider: provider, sessionID: sessionID, root: root, modifiedAt: modifiedAt ?? nil, bytes: bytes, fileCount: fileCount, scanTruncated: truncated, unavailableReason: nil)
    }

    private static func isOwnedRun(_ root: URL, fileManager: FileManager) -> Bool {
        let marker = root.appendingPathComponent(ownershipMarkerName)
        return isRegularFile(marker, fileManager: fileManager)
            && (try? String(contentsOf: marker, encoding: .utf8))?.hasPrefix(ownershipMarkerPrefix) == true
    }

    private static func safePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private static func safeCanonicalRoot(homeDirectory: URL) -> URL? {
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let root = canonicalRoot(homeDirectory: homeDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        guard root == home || root.hasPrefix(home.hasSuffix("/") ? home : home + "/") else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    private static func directoryContents(_ url: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [])) ?? []
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
