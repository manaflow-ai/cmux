import Foundation

/// Serializes daemon flushes; reads and in-process edits use CFPreferences' cache.
actor CloudTreeExpansionPreferencesWriter {
    private let applicationID: String?

    init(applicationID: String?) { self.applicationID = applicationID }

    @discardableResult
    func flush() -> Bool {
        CFPreferencesAppSynchronize(applicationID.map { $0 as CFString } ?? ProcessDefaultsDomain.cfApplicationID)
    }
}
