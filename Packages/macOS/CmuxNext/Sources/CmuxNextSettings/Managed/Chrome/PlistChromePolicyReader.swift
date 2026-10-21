public import Foundation

/// Reads a plist shaped like a Chrome policy profile payload (tests, DEV
/// builds): top-level keys are mandatory, keys under a top-level
/// `Recommended` dictionary are recommended. A missing or unreadable file is empty.
public nonisolated struct PlistChromePolicyReader: ChromePolicyReading {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> ChromePolicyDocument {
        let managed = PlistManagedPreferenceReader(url: url).read()
        return ChromePolicyDocument(mandatory: managed.forced, recommended: managed.recommended)
    }
}
