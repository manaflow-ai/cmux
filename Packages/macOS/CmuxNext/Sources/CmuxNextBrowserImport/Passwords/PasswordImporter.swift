public import Foundation

/// One source profile's password import, as the user sees it: "412
/// imported, 9 skipped".
public struct PasswordImportReport: Sendable, Equatable, Codable {
    public var read = 0
    public var skipped = LoginSkipCounts()
    public var store = PasswordStoreReply()

    public init() {}

    public var imported: Int { store.added }
    /// Everything that did not become a new saved password.
    public var notImported: Int { skipped.total + store.duplicate + store.conflict + store.rejected }
}

/// Imports one Chromium source profile's saved passwords into one cmux
/// browser profile. Runs only after the user agreed on the consent screen:
/// the Keychain read below is what makes macOS ask about the source's
/// "<Name> Safe Storage" item. Blocks on that prompt; call off the main thread.
public struct PasswordImporter: Sendable {
    public enum Failure: Error, Equatable, Sendable, Codable {
        /// Only Chromium browsers keep passwords cmux can read.
        case unsupportedBrowser
        /// The build cannot write passwords yet.
        case storeUnavailable
        case key(CookieImportError)
        /// The Login Data file would not open or read.
        case unreadable
    }

    let keys: any SafeStorageKeyProviding
    let destination: any PasswordDestination

    public init(keys: any SafeStorageKeyProviding, destination: any PasswordDestination) {
        self.keys = keys
        self.destination = destination
    }

    public func run(_ profile: BrowserSourceProfile, intoProfile profileID: String) async throws -> PasswordImportReport {
        guard profile.browser.family == .chromium, !profile.browser.refusesSessionData,
              let service = profile.browser.safeStorageService else { throw Failure.unsupportedBrowser }
        guard destination.isAvailable else { throw Failure.storeUnavailable }
        let crypto: ChromiumPasswordCrypto
        do {
            // The Keychain reply is Security's buffer; it is copied into
            // SecretBytes and released here, before any value is read.
            let password = try keys.password(service: service)
            crypto = ChromiumPasswordCrypto(safeStoragePassword: password)
        } catch let error as CookieImportError {
            throw Failure.key(error)
        }
        let read: (logins: [ImportedLogin], skipped: LoginSkipCounts)
        do {
            read = try ChromiumLoginDataReader().read(profile: profile.path, crypto: crypto)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreadable
        }
        let (logins, skipped) = read
        var report = PasswordImportReport()
        report.read = logins.count + skipped.total
        report.skipped = skipped
        if !logins.isEmpty { report.store = try await destination.add(logins, toProfile: profileID) }
        // `logins` goes out of scope here: every SecretBytes is zeroed and freed.
        return report
    }
}
