/// Localized warning message text passed into ``BrowserDataImportService`` from
/// the app.
///
/// Localization must stay app-side: `String(localized:)` resolved inside this
/// package would bind to the package bundle (which lacks the
/// `browser.import.warning.*` keys) and silently drop every non-English
/// translation. The app resolves these strings in its own bundle and passes them
/// through this seam so import warnings surface faithfully localized messages.
///
/// Fields named `…Format` are `String(format:)` templates; the engine
/// interpolates them with the runtime values (browser name, file name, error
/// description, skipped count, keychain item name). `%ld` arguments are the
/// `Int` skipped/encrypted counts; `%@` arguments are the strings, in declaration
/// order.
public struct BrowserImportWarningStrings: Sendable {
    /// Note shown after an "everything" import that other data tiers are not yet
    /// supported. No format arguments.
    public let additionalDataUnavailable: String
    /// Warning that Safari cookies are stored in an unsupported binary format. No
    /// format arguments.
    public let safariCookiesUnsupported: String
    /// `%@` template (browser name) for an unimplemented cookie importer.
    public let cookieImportUnsupportedFormat: String
    /// `%@ %@` template (file name, error) for a failed Firefox cookie read.
    public let firefoxCookiesReadFailedFormat: String
    /// `%@ %@ %@` template (browser name, file name, error) for a failed cookie read.
    public let browserCookiesReadFailedFormat: String
    /// `%@ %@` template (file name, error) for a failed Firefox history read.
    public let firefoxHistoryReadFailedFormat: String
    /// `%@ %@ %@` template (browser name, file name, error) for a failed history read.
    public let browserHistoryReadFailedFormat: String
    /// `%@` template (browser name) when no history database is found.
    public let noHistoryDatabaseFormat: String
    /// `%ld %@ %@` template (skipped count, browser name, keychain item name) for
    /// cookies skipped because the keychain secret could not be unlocked.
    public let keychainDecryptFailedFormat: String
    /// `%ld` template (skipped count) for encrypted cookies skipped without a
    /// keychain decryption path.
    public let encryptedCookiesSkippedFormat: String

    /// Creates the warning strings bundle.
    /// - Parameters:
    ///   - additionalDataUnavailable: Note that other data tiers are unsupported.
    ///   - safariCookiesUnsupported: Warning for unsupported Safari cookie storage.
    ///   - cookieImportUnsupportedFormat: `%@` template for an unimplemented importer.
    ///   - firefoxCookiesReadFailedFormat: `%@ %@` template for a Firefox cookie read failure.
    ///   - browserCookiesReadFailedFormat: `%@ %@ %@` template for a cookie read failure.
    ///   - firefoxHistoryReadFailedFormat: `%@ %@` template for a Firefox history read failure.
    ///   - browserHistoryReadFailedFormat: `%@ %@ %@` template for a history read failure.
    ///   - noHistoryDatabaseFormat: `%@` template for a missing history database.
    ///   - keychainDecryptFailedFormat: `%ld %@ %@` template for keychain-locked cookies.
    ///   - encryptedCookiesSkippedFormat: `%ld` template for skipped encrypted cookies.
    public init(
        additionalDataUnavailable: String,
        safariCookiesUnsupported: String,
        cookieImportUnsupportedFormat: String,
        firefoxCookiesReadFailedFormat: String,
        browserCookiesReadFailedFormat: String,
        firefoxHistoryReadFailedFormat: String,
        browserHistoryReadFailedFormat: String,
        noHistoryDatabaseFormat: String,
        keychainDecryptFailedFormat: String,
        encryptedCookiesSkippedFormat: String
    ) {
        self.additionalDataUnavailable = additionalDataUnavailable
        self.safariCookiesUnsupported = safariCookiesUnsupported
        self.cookieImportUnsupportedFormat = cookieImportUnsupportedFormat
        self.firefoxCookiesReadFailedFormat = firefoxCookiesReadFailedFormat
        self.browserCookiesReadFailedFormat = browserCookiesReadFailedFormat
        self.firefoxHistoryReadFailedFormat = firefoxHistoryReadFailedFormat
        self.browserHistoryReadFailedFormat = browserHistoryReadFailedFormat
        self.noHistoryDatabaseFormat = noHistoryDatabaseFormat
        self.keychainDecryptFailedFormat = keychainDecryptFailedFormat
        self.encryptedCookiesSkippedFormat = encryptedCookiesSkippedFormat
    }
}
