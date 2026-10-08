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
    /// Sign-ins cmux already has for that site and username with another
    /// password: the saved one was kept. Summaries show this count on its own
    /// so a differing password is never dropped silently.
    public var conflicts: Int { store.conflict }
    /// What did not become a new saved password, other than `conflicts`.
    public var notImportedOtherThanConflicts: Int { notImported - conflicts }
}

/// Imports one source profile's saved passwords into one cmux browser
/// profile. Runs only after the user agreed on the consent screen. Chromium
/// sources: the Keychain read below is what makes macOS ask about the
/// source's "<Name> Safe Storage" item (blocks on that prompt; call off the
/// main thread). Firefox sources: NSS `key4.db`; when the profile has a
/// primary password, `primaryPassword` asks the person for it (a native
/// secure field), and a cancel or a wrong one fails only these passwords.
public struct PasswordImporter: Sendable {
    public enum Failure: Error, Equatable, Sendable, Codable {
        /// Only Chromium and Firefox browsers keep passwords cmux can read.
        case unsupportedBrowser
        /// The build cannot write passwords yet.
        case storeUnavailable
        case key(CookieImportError)
        /// The Login Data file would not open or read.
        case unreadable
        /// Firefox: the profile has a primary password and the person gave none.
        case primaryPasswordNeeded
        /// Firefox: the primary password given does not open the profile.
        case wrongPrimaryPassword
    }

    /// Asks the person for a Firefox profile's primary password; nil when they cancel.
    public typealias PrimaryPasswordPrompt = @Sendable (BrowserSourceProfile) async -> SecretBytes?

    let keys: any SafeStorageKeyProviding
    let destination: any PasswordDestination
    let primaryPassword: PrimaryPasswordPrompt?

    public init(keys: any SafeStorageKeyProviding, destination: any PasswordDestination, primaryPassword: PrimaryPasswordPrompt? = nil) {
        self.keys = keys
        self.destination = destination
        self.primaryPassword = primaryPassword
    }

    public func run(_ profile: BrowserSourceProfile, intoProfile profileID: String) async throws -> PasswordImportReport {
        #if CMUX_NO_PASSWORD_IMPORT
        // The cx-f58x notary test build has no browser password readers.
        throw Failure.unsupportedBrowser
        #else
        if profile.browser.family == .firefox, !profile.browser.refusesSessionData {
            guard destination.isAvailable else { throw Failure.storeUnavailable }
            return try await store(try await readFirefox(profile), intoProfile: profileID)
        }
        guard profile.browser.family == .chromium, profile.browser.readsSavedPasswords,
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
        return try await store(read, intoProfile: profileID)
        #endif
    }

    #if !CMUX_NO_PASSWORD_IMPORT
    /// Reads with no primary password first; asks the person once when the profile has one.
    private func readFirefox(_ profile: BrowserSourceProfile) async throws -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        do {
            return try FirefoxLoginReader().read(profile: profile.path, primaryPassword: nil)
        } catch FirefoxPasswordCrypto.Failure.primaryPasswordNeeded {
            guard let primaryPassword, let given = await primaryPassword(profile), !given.isEmpty else { throw Failure.primaryPasswordNeeded }
            do {
                return try FirefoxLoginReader().read(profile: profile.path, primaryPassword: given)
            } catch FirefoxPasswordCrypto.Failure.wrongPrimaryPassword {
                throw Failure.wrongPrimaryPassword
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.unreadable
            }
            // `given` goes out of scope here and is zeroed.
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable
        }
    }

    #endif

    private func store(_ read: (logins: [ImportedLogin], skipped: LoginSkipCounts), intoProfile profileID: String) async throws -> PasswordImportReport {
        let (logins, skipped) = read
        var report = PasswordImportReport()
        report.read = logins.count + skipped.total
        report.skipped = skipped
        if !logins.isEmpty { report.store = try await destination.add(logins, toProfile: profileID) }
        // `logins` goes out of scope here: every SecretBytes is zeroed and freed.
        return report
    }
}
