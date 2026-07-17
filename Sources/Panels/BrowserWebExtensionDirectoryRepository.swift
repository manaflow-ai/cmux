import CryptoKit
import Foundation

struct BrowserWebExtensionApprovalDiscoveryResult: Sendable {
    struct Failure: Sendable {
        let url: URL
        let message: String
    }

    let candidates: [URL]
    let failures: [Failure]
}

/// Moves extension-directory enumeration and metadata reads off the main actor.
@available(macOS 15.4, *)
actor BrowserWebExtensionDirectoryRepository {
    private static let approvalFileName = ".cmux-approved-extensions.json"
    private var isShutDown = false

    func shutdownAndRemoveDirectory(_ directory: URL) {
        isShutDown = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func requireActive() throws {
        guard !isShutDown else { throw CancellationError() }
    }

    func candidateURLs(in directory: URL) -> [URL] {
        BrowserWebExtensionsManager.candidateURLs(in: directory)
    }

    func approvedCandidateURLs(in directory: URL) throws -> BrowserWebExtensionApprovalDiscoveryResult {
        try requireActive()
        let approvals = try readApprovals(in: directory)
        var candidates: [URL] = []
        var failures: [BrowserWebExtensionApprovalDiscoveryResult.Failure] = []
        for candidate in candidateURLs(in: directory) {
            guard let approvedDigest = approvals[candidate.lastPathComponent] else { continue }
            do {
                if try packageDigest(for: candidate) == approvedDigest {
                    candidates.append(candidate)
                }
            } catch {
                failures.append(.init(url: candidate, message: error.localizedDescription))
            }
        }
        return BrowserWebExtensionApprovalDiscoveryResult(
            candidates: candidates,
            failures: failures
        )
    }

    func approveCandidate(at candidate: URL, in directory: URL) throws {
        try requireActive()
        let managedDirectory = directory.standardizedFileURL
        guard candidate.standardizedFileURL.deletingLastPathComponent() == managedDirectory else {
            throw BrowserWebExtensionInstallError.outsideManagedDirectory
        }
        var approvals = try readApprovals(in: directory)
        approvals[candidate.lastPathComponent] = try packageDigest(for: candidate)
        try writeApprovals(approvals, in: directory)
    }

    func installCandidate(from source: URL, into directory: URL) throws -> URL {
        try requireActive()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: source.hasDirectoryPath
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BrowserWebExtensionInstallError.alreadyInstalled(source.lastPathComponent)
        }
        let stagingName = ".cmux-install-\(UUID().uuidString)"
            + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
        let staging = directory.appendingPathComponent(
            stagingName,
            isDirectory: source.hasDirectoryPath
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    func removeInstalledCandidate(at url: URL, from directory: URL) {
        try? FileManager.default.removeItem(at: url)
        guard !isShutDown else { return }
        guard var approvals = try? readApprovals(in: directory) else { return }
        approvals.removeValue(forKey: url.lastPathComponent)
        try? writeApprovals(approvals, in: directory)
    }

    private func readApprovals(in directory: URL) throws -> [String: String] {
        let url = directory.appendingPathComponent(Self.approvalFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func writeApprovals(_ approvals: [String: String], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(approvals)
        try data.write(
            to: directory.appendingPathComponent(Self.approvalFileName),
            options: [.atomic, .completeFileProtection]
        )
    }

    private func packageDigest(for candidate: URL) throws -> String {
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
        }
        if values.isDirectory != true {
            return Self.hexDigest(SHA256.hash(data: try Data(contentsOf: candidate)))
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: candidate,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw BrowserWebExtensionInstallError.invalidPackage(candidate.lastPathComponent)
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let fileValues = try fileURL.resourceValues(forKeys: Set(keys))
            if fileValues.isSymbolicLink == true {
                throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
            }
            if fileValues.isRegularFile == true { files.append(fileURL) }
        }
        files.sort { $0.path < $1.path }

        var hasher = SHA256()
        for fileURL in files {
            let relativePath = String(fileURL.path.dropFirst(candidate.path.count + 1))
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            try handle.close()
            hasher.update(data: Data([0]))
        }
        return Self.hexDigest(hasher.finalize())
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum BrowserWebExtensionInstallError: LocalizedError {
    case alreadyInstalled(String)
    case outsideManagedDirectory
    case symbolicLinksNotAllowed
    case invalidPackage(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name):
            return String(
                localized: "browser.extensions.install.alreadyInstalled",
                defaultValue: "\(name) is already installed."
            )
        case .outsideManagedDirectory:
            return String(
                localized: "browser.extensions.install.outsideManagedDirectory",
                defaultValue: "The extension must be inside the managed extensions directory."
            )
        case .symbolicLinksNotAllowed:
            return String(
                localized: "browser.extensions.install.symbolicLinksNotAllowed",
                defaultValue: "Extensions containing symbolic links cannot be installed."
            )
        case .invalidPackage(let name):
            return String(
                localized: "browser.extensions.install.invalidPackage",
                defaultValue: "\(name) is not a readable extension package."
            )
        }
    }
}
