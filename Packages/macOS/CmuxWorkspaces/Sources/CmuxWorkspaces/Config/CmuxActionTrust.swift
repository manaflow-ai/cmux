public import Foundation

/// Disk-backed store of trusted project-local config-action fingerprints. Holds
/// the set of ``CmuxActionTrustDescriptor`` fingerprints the user has approved,
/// persisted as a JSON array of strings at the injected ``storePath`` (the app
/// composition root supplies the Application Support path). Mutations save
/// immediately and post ``didChangeNotification`` so config consumers reload.
///
/// On-disk format contract: a JSON array of the sorted fingerprint strings,
/// written to `storePath`, byte-identical to the legacy app-target store at
/// `Application Support/cmux/trusted-actions.json`.
///
/// The shared production instance is constructed app-side (the package does not
/// own a `static let shared`, per the de-singletonization rule); inject a scoped
/// `storePath` in tests.
public final class CmuxActionTrust {
    /// Posted on the main `NotificationCenter` whenever the trusted set changes.
    public static let didChangeNotification = Notification.Name("cmux.actionTrustDidChange")

    private let storePath: String
    private var trustedFingerprints: Set<String>

    /// Creates a store backed by the JSON file at `storePath`, creating its parent
    /// directory if missing and loading any existing fingerprints.
    public init(storePath: String) {
        self.storePath = storePath

        let fm = FileManager.default
        let directory = (storePath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        if let data = fm.contents(atPath: storePath),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            trustedFingerprints = Set(values)
        } else {
            trustedFingerprints = []
        }
    }

    /// Whether `descriptor`'s fingerprint is in the trusted set.
    public func isTrusted(_ descriptor: CmuxActionTrustDescriptor) -> Bool {
        trustedFingerprints.contains(descriptor.fingerprint)
    }

    /// Adds `descriptor`'s fingerprint to the trusted set and persists.
    public func trust(_ descriptor: CmuxActionTrustDescriptor) {
        trustedFingerprints.insert(descriptor.fingerprint)
        save()
    }

    /// Clears every trusted fingerprint and persists.
    public func clearAll() {
        trustedFingerprints.removeAll()
        save()
    }

    /// The trusted fingerprints in sorted order.
    public var allTrustedFingerprints: [String] {
        trustedFingerprints.sorted()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(trustedFingerprints.sorted()) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
