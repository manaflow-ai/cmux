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
            id: "1password",
            version: "8.12.28.25",
            packageURL: URL(
                string: "https://addons.mozilla.org/firefox/downloads/file/4899098/1password_x_password_manager-8.12.28.25.xpi"
            )!,
            packageSHA256: "fc369b5ee7958a57c519aa37e7ba540ebe08d58b4bc976fab1ba2e91bc01bc25"
        ),
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

final class BrowserWebExtensionPackageSession: @unchecked Sendable {
    static let defaultMaximumResponseByteCount = 25 * 1024 * 1024

    private let redirectDelegate: BrowserWebExtensionHTTPSRedirectDelegate
    private let session: URLSession
    private let maximumResponseByteCount: Int

    init(
        configuration: sending URLSessionConfiguration = .ephemeral,
        maximumResponseByteCount: Int = defaultMaximumResponseByteCount
    ) {
        precondition(maximumResponseByteCount > 0)
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = BrowserWebExtensionHTTPSRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.maximumResponseByteCount = maximumResponseByteCount
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        if response.expectedContentLength > maximumResponseByteCount {
            bytes.task.cancel()
            throw BrowserWebExtensionCatalogInstallError.packageTooLarge
        }
        let data = try await Self.collect(
            bytes,
            maximumByteCount: maximumResponseByteCount,
            expectedByteCount: max(0, Int(response.expectedContentLength)),
            cancel: { bytes.task.cancel() }
        )
        return (data, response)
    }

    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumByteCount: Int,
        expectedByteCount: Int = 0,
        cancel: @Sendable () -> Void
    ) async throws -> Data where Bytes.Element == UInt8 {
        precondition(maximumByteCount > 0)
        var data = Data()
        data.reserveCapacity(min(expectedByteCount, maximumByteCount))
        for try await byte in bytes {
            guard data.count < maximumByteCount else {
                cancel()
                throw BrowserWebExtensionCatalogInstallError.packageTooLarge
            }
            data.append(byte)
        }
        return data
    }

    deinit {
        session.invalidateAndCancel()
    }
}

final class BrowserWebExtensionHTTPSRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard newRequest.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(newRequest)
    }
}

actor BrowserWebExtensionCatalogPackageRepository {
    private let packageSession: BrowserWebExtensionPackageSession

    init(packageSession: BrowserWebExtensionPackageSession = BrowserWebExtensionPackageSession()) {
        self.packageSession = packageSession
    }

    func download(_ entry: BrowserWebExtensionCatalogEntry) async throws -> URL {
        guard entry.packageURL.scheme?.lowercased() == "https" else {
            throw BrowserWebExtensionCatalogInstallError.insecurePackageURL
        }

        let (data, response) = try await packageSession.data(from: entry.packageURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else {
            throw BrowserWebExtensionCatalogInstallError.invalidHTTPResponse
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
