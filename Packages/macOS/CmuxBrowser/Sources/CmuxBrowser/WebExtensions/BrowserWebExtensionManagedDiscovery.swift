public import Foundation

/// Validated durable extension records discovered for one profile.
public struct BrowserWebExtensionManagedDiscovery: Sendable {
    /// A record paired with its current package or Safari extension URL.
    public struct Installation: Sendable {
        public let record: BrowserWebExtensionManagedRecord
        public let resourceURL: URL

        public init(record: BrowserWebExtensionManagedRecord, resourceURL: URL) {
            self.record = record
            self.resourceURL = resourceURL
        }
    }

    /// A stable, sanitized record failure.
    public struct Failure: Sendable {
        public let recordID: String
        public let entryName: String

        public init(recordID: String, entryName: String) {
            self.recordID = recordID
            self.entryName = entryName
        }
    }

    public let installations: [Installation]
    public let failures: [Failure]

    public init(installations: [Installation], failures: [Failure]) {
        self.installations = installations
        self.failures = failures
    }
}
