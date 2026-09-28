import Foundation

/// Persists outline restoration state without broadcasting a settings change.
///
/// These keys have no settings consumers. Core Foundation keeps the existing app
/// domain and keys, but does not post UserDefaults.didChangeNotification for each
/// disclosure. Flushing the preferences daemon runs off the AppKit event path.
struct CloudTreeExpansionPreferences: CloudTreeExpansionPersistence {
    private let applicationID: String?
    private let writer: CloudTreeExpansionPreferencesWriter

    /// A nil domain passes Core Foundation's current-application sentinel intact.
    init(applicationID: String? = nil) {
        self.applicationID = applicationID
        writer = CloudTreeExpansionPreferencesWriter(applicationID: applicationID)
    }

    func stringArray(forKey key: String) -> [String]? {
        CFPreferencesCopyAppValue(key as CFString, domain) as? [String]
    }

    @discardableResult
    func setIfChanged(_ value: [String], forKey key: String) -> Bool {
        guard stringArray(forKey: key) != value else { return false }
        CFPreferencesSetAppValue(key as CFString, value as CFArray, domain)
        Task { await writer.flush() }
        return true
    }

    /// Waits for durable persistence without blocking the main thread.
    @discardableResult
    func flush() async -> Bool { await writer.flush() }

    private var domain: CFString {
        applicationID.map { $0 as CFString } ?? kCFPreferencesCurrentApplication
    }
}
