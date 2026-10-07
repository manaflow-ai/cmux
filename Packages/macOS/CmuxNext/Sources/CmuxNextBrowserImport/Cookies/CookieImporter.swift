public import Foundation

/// The cookie step of an import: read one source profile's cookies with its
/// own reader (decrypting Chromium values with the source's Keychain key)
/// and hand them to the target profile's store in batches. Cookies exist
/// only in memory during this call; the result is counts.
public struct CookieImporter: Sendable {
    public var destination: any CookieDestination
    public var keys: any SafeStorageKeyProviding
    /// Cookies per `setCookies` call (bounds one shim message).
    public var batchSize = 500

    public init(destination: any CookieDestination, keys: any SafeStorageKeyProviding) {
        self.destination = destination
        self.keys = keys
    }

    public func run(_ profile: BrowserSourceProfile, into target: String, now: Date = Date()) async throws -> CookieImportReport {
        let read = try Self.read(profile, keys: keys, now: now)
        var report = CookieImportReport(undecryptable: read.undecryptable, partitioned: read.partitioned, expired: read.expired)
        var start = 0
        while start < read.cookies.count { // wakeup-allow: bounded by the cookie count
            try Task.checkCancellation()
            let slice = Array(read.cookies[start..<min(start + batchSize, read.cookies.count)])
            let written = try await destination.setCookies(slice, profileID: target)
            report.written += written.written
            report.rejected += written.rejected
            start += slice.count
        }
        return report
    }

    /// Reads (and decrypts) the cookies of one profile. Blocks on the
    /// Keychain prompt for Chromium browsers.
    static func read(_ profile: BrowserSourceProfile, keys: any SafeStorageKeyProviding, now: Date) throws -> CookieReadResult {
        let browser = profile.browser
        if browser.refusesSessionData { throw CookieImportError.refused }
        switch browser.family {
        case .chromium:
            guard let file = BrowserSourceDetector.chromiumCookieFile(profile.path), let service = browser.safeStorageService else {
                return CookieReadResult(cookies: [])
            }
            // The cookie crypto takes `Data` (one short-lived copy of the key, freed after this read).
            let password = try keys.password(service: service).withUnsafeBytes { Data($0) }
            return try ChromiumCookieReader().read(file, crypto: ChromiumCookieCrypto(safeStoragePassword: password), now: now)
        case .firefox:
            return try FirefoxCookieReader().read(profile.path.appending(path: "cookies.sqlite"), now: now)
        case .safari:
            // `path` is ~/Library/Safari; the cookie file is in Safari's container.
            guard let relative = browser.safariCookieFile else { return CookieReadResult(cookies: []) }
            let home = profile.path.deletingLastPathComponent().deletingLastPathComponent()
            let file = home.appending(path: relative)
            switch FileAccess.probe(file) {
            case .denied: throw CookieImportError.needsFullDiskAccess
            case .missing: return CookieReadResult(cookies: [])
            case .readable: return try SafariBinaryCookies().parse(Data(contentsOf: file), now: now)
            }
        case .webkit:
            throw CookieImportError.malformed(browser.displayName)
        }
    }
}
