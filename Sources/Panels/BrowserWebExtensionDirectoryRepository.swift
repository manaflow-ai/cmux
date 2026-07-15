import Foundation

/// Moves extension-directory enumeration and metadata reads off the main actor.
@available(macOS 15.4, *)
actor BrowserWebExtensionDirectoryRepository {
    func candidateURLs(in directory: URL) -> [URL] {
        BrowserWebExtensionsManager.candidateURLs(in: directory)
    }

    func installCandidate(from source: URL, into directory: URL) throws -> URL {
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

    func removeInstalledCandidate(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

enum BrowserWebExtensionInstallError: LocalizedError {
    case alreadyInstalled(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name):
            return String(
                localized: "browser.extensions.install.alreadyInstalled",
                defaultValue: "\(name) is already installed."
            )
        }
    }
}
