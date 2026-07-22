import CryptoKit
public import Foundation

public struct BrowserWebExtensionCatalogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let packageURL: URL
    public let packageSHA256: String
    public let archiveLimits: BrowserWebExtensionArchiveLimits

    public var installationFilename: String {
        "cmux-catalog-\(id)-\(version).zip"
    }

    public var installedManagementID: String {
        "catalog:\(id)"
    }

    public init(
        id: String,
        version: String,
        packageURL: URL,
        packageSHA256: String,
        archiveLimits: BrowserWebExtensionArchiveLimits = .standard
    ) {
        self.id = id
        self.version = version
        self.packageURL = packageURL
        self.packageSHA256 = packageSHA256
        self.archiveLimits = archiveLimits
    }
}

public struct BrowserWebExtensionCatalog: Equatable, Sendable {
    /// Entries are published only after their exact package and required WebKit
    /// APIs have been exercised in cmux. A pinned digest makes an upstream asset
    /// change fail closed instead of silently changing installed code.
    public static let production = BrowserWebExtensionCatalog(
        verifiedEntries: [
            BrowserWebExtensionCatalogEntry(
                id: "1password",
                version: "8.12.28.25",
                packageURL: URL(
                    string: "https://addons.mozilla.org/firefox/downloads/file/4899098/1password_x_password_manager-8.12.28.25.xpi"
                )!,
                packageSHA256: "fc369b5ee7958a57c519aa37e7ba540ebe08d58b4bc976fab1ba2e91bc01bc25"
            ),
        ],
        safariAppIdentities: [
        BrowserWebExtensionSafariAppIdentity(
            id: "bitwarden-safari-app",
            appBundleIdentifier: "com.bitwarden.desktop",
            extensionBundleIdentifier: "com.bitwarden.desktop.safari",
            teamIdentifier: "LTZ2PFU5D6"
        ),
        BrowserWebExtensionSafariAppIdentity(
            id: "ublock-origin-lite-safari-app",
            appBundleIdentifier: "net.raymondhill.uBlock-Origin-Lite",
            extensionBundleIdentifier: "net.raymondhill.uBlock-Origin-Lite.Extension",
            teamIdentifier: "WY4R6PNRF6"
        ),
        ]
    )

    public let verifiedEntries: [BrowserWebExtensionCatalogEntry]
    public let safariAppIdentities: [BrowserWebExtensionSafariAppIdentity]

    public init(
        verifiedEntries: [BrowserWebExtensionCatalogEntry],
        safariAppIdentities: [BrowserWebExtensionSafariAppIdentity]
    ) {
        self.verifiedEntries = verifiedEntries
        self.safariAppIdentities = safariAppIdentities
    }

    public func entry(id: String) -> BrowserWebExtensionCatalogEntry? {
        verifiedEntries.first { $0.id == id }
    }
}

public enum BrowserWebExtensionCatalogInstallError: LocalizedError, Equatable {
    case insecurePackageURL
    case invalidHTTPResponse
    case packageTooLarge
    case integrityMismatch

    public var errorDescription: String? {
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

public struct BrowserWebExtensionPackageVerifier: Sendable {
    public init() {}

    public func verify(_ data: Data, expectedSHA256: String) throws {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw BrowserWebExtensionCatalogInstallError.integrityMismatch
        }
    }
}

public final class BrowserWebExtensionPackageSession: @unchecked Sendable {
    public static let defaultMaximumResponseByteCount = 25 * 1024 * 1024

    private let redirectDelegate: BrowserWebExtensionHTTPSRedirectDelegate
    private let session: URLSession
    private let maximumResponseByteCount: Int

    public init(
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

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        try Self.validateExpectedContentLength(
            response,
            maximumByteCount: maximumResponseByteCount,
            cancel: { bytes.task.cancel() }
        )
        let data = try await Self.collect(
            bytes,
            maximumByteCount: maximumResponseByteCount,
            expectedByteCount: max(0, Int(response.expectedContentLength)),
            cancel: { bytes.task.cancel() }
        )
        return (data, response)
    }

    static func validateExpectedContentLength(
        _ response: URLResponse,
        maximumByteCount: Int,
        cancel: @Sendable () -> Void
    ) throws {
        precondition(maximumByteCount > 0)
        guard response.expectedContentLength <= maximumByteCount else {
            cancel()
            throw BrowserWebExtensionCatalogInstallError.packageTooLarge
        }
    }

    public static func collect<Bytes: AsyncSequence>(
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

public final class BrowserWebExtensionHTTPSRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    public func urlSession(
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

public actor BrowserWebExtensionCatalogPackageRepository {
    private let packageSession: BrowserWebExtensionPackageSession

    public init(packageSession: BrowserWebExtensionPackageSession = BrowserWebExtensionPackageSession()) {
        self.packageSession = packageSession
    }

    public func download(_ entry: BrowserWebExtensionCatalogEntry) async throws -> URL {
        guard entry.packageURL.scheme?.lowercased() == "https" else {
            throw BrowserWebExtensionCatalogInstallError.insecurePackageURL
        }

        let (data, response) = try await packageSession.data(from: entry.packageURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else {
            throw BrowserWebExtensionCatalogInstallError.invalidHTTPResponse
        }
        try BrowserWebExtensionPackageVerifier().verify(data, expectedSHA256: entry.packageSHA256)

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

    public func removeDownloadedPackage(at packageURL: URL) {
        try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent())
    }
}
