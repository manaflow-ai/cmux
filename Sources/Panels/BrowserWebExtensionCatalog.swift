import CryptoKit
import Foundation

struct BrowserWebExtensionCatalogEntry: Identifiable, Equatable, Sendable {
    let id: String
    let version: String
    let packageURL: URL
    let packageSHA256: String

    var installationFilename: String {
        "cmux-catalog-\(id)-\(version).zip"
    }

    var installedExtensionIdentifier: String {
        "cmux-browser-extension-\(installationFilename)"
    }
}

enum BrowserWebExtensionCatalog {
    /// Entries are published only after their exact package and required WebKit
    /// APIs have been exercised in cmux. A pinned digest makes an upstream asset
    /// change fail closed instead of silently changing installed code.
    static let verifiedEntries: [BrowserWebExtensionCatalogEntry] = [
        BrowserWebExtensionCatalogEntry(
            id: "video-speed-controller",
            version: "0.10.2",
            packageURL: URL(
                string: "https://github.com/igrigorik/videospeed/releases/download/v0.10.2/videospeed-0.10.2.zip"
            )!,
            packageSHA256: "f75a35f2ea9d1af3c861fb423b219418a8dc87982462cc88d1ce1223abe48d61"
        ),
    ]

    static func entry(id: String) -> BrowserWebExtensionCatalogEntry? {
        verifiedEntries.first { $0.id == id }
    }
}

enum BrowserWebExtensionCatalogInstallError: LocalizedError, Equatable {
    case insecurePackageURL
    case invalidHTTPResponse
    case packageTooLarge
    case integrityMismatch

    var errorDescription: String? {
        switch self {
        case .insecurePackageURL:
            return String(
                localized: "browser.extensions.store.error.insecureURL",
                defaultValue: "The extension package must use HTTPS."
            )
        case .invalidHTTPResponse:
            return String(
                localized: "browser.extensions.store.error.download",
                defaultValue: "The extension package could not be downloaded."
            )
        case .packageTooLarge:
            return String(
                localized: "browser.extensions.store.error.tooLarge",
                defaultValue: "The extension package is larger than 25 MB."
            )
        case .integrityMismatch:
            return String(
                localized: "browser.extensions.store.error.integrity",
                defaultValue: "The extension package failed its integrity check."
            )
        }
    }
}

enum BrowserWebExtensionPackageVerifier {
    static func verify(_ data: Data, expectedSHA256: String) throws {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw BrowserWebExtensionCatalogInstallError.integrityMismatch
        }
    }
}

actor BrowserWebExtensionCatalogPackageRepository {
    private static let maximumPackageBytes = 25 * 1024 * 1024

    func download(_ entry: BrowserWebExtensionCatalogEntry) async throws -> URL {
        guard entry.packageURL.scheme?.lowercased() == "https" else {
            throw BrowserWebExtensionCatalogInstallError.insecurePackageURL
        }

        let (downloadURL, response) = try await URLSession.shared.download(from: entry.packageURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else {
            throw BrowserWebExtensionCatalogInstallError.invalidHTTPResponse
        }
        let resourceValues = try downloadURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = resourceValues.fileSize,
              fileSize <= Self.maximumPackageBytes else {
            throw BrowserWebExtensionCatalogInstallError.packageTooLarge
        }
        let data = try Data(contentsOf: downloadURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumPackageBytes else {
            throw BrowserWebExtensionCatalogInstallError.packageTooLarge
        }
        try BrowserWebExtensionPackageVerifier.verify(data, expectedSHA256: entry.packageSHA256)

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-extension-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let packageURL = stagingDirectory.appendingPathComponent(entry.installationFilename)
        do {
            try data.write(to: packageURL, options: .atomic)
            return packageURL
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func removeDownloadedPackage(at packageURL: URL) {
        try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent())
    }
}
