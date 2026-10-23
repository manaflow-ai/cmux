import CryptoKit
import Foundation

/// Which settings problems the app tells the person about, and when. A load
/// never fails on a bad entry: the entry is skipped and reported in
/// ``SettingsDiagnostic``. Without a notice an agent or a hand edit could set
/// a value this build refuses (a background form it does not know, a wrong
/// type) and the app would silently fall back to the default.
///
/// A notice is the key, the value the file holds there and the reason. Each
/// one is announced once: ``update`` returns the refusals not announced yet,
/// and ``announced`` records the ones a toast showed (a refusal with no window
/// to show it in stays pending). The same refusal on a later reload or launch
/// stays quiet (the app keeps ``remembered`` across launches), a different bad
/// value at the key is announced, and a refusal that was fixed is announced
/// again when it comes back. Not announced: keys an MDM profile or the team
/// policy manages, and policy-only keys (`DisabledFeatures`): the person did
/// not set them. Nor shortcut conflicts, which the defaults alone can make.
/// Settings lists all of them at their rows.
public struct SettingsDiagnosticNotices: Sendable {
    public struct Notice: Sendable, Hashable {
        /// Dotted key ("" for the whole file).
        public let path: String
        /// The file's value at the key as compact JSON, nil when it has none.
        public let value: String?
        public let message: String
        /// What ``remembered`` stores: the key, a digest of the value (never
        /// the value itself) and the reason. A file that does not parse is one
        /// notice whatever the parse error says, so an autosave that moves the
        /// error does not announce it again.
        public let fingerprint: String

        public init(kind: SettingsDiagnostic.Kind = .invalidValue, path: String, value: String?, message: String) {
            self.path = path
            self.value = value
            self.message = message
            if kind == .unreadableFile {
                fingerprint = kind.rawValue
            } else {
                let digest = value.map { SHA256.hash(data: Data($0.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() } ?? ""
                fingerprint = [path, digest, message].joined(separator: "\u{0}")
            }
        }
    }

    public struct Update: Sendable, Equatable {
        /// Refusals not announced yet, in the load's order.
        public let announce: [Notice]
        /// The refusal the shown toast is about is gone: the toast can close.
        public let cleared: Bool
    }

    /// Fingerprints of the refusals announced and not fixed since: at launch
    /// the ones an earlier launch announced.
    public private(set) var remembered: Set<String>
    /// The fingerprint the shown toast names.
    private var shown: String?

    public init(remembered: Set<String> = []) {
        self.remembered = remembered
    }

    /// The kinds that mean the file's own value was dropped.
    public static func announces(_ kind: SettingsDiagnostic.Kind) -> Bool {
        switch kind {
        case .unreadableFile, .invalidValue, .unknownAction, .unknownMetric, .unsupportedChord, .removedSetting: true
        case .shortcutConflict, .managedOverride, .managedConflict: false
        }
    }

    /// Takes one load's diagnostics, the user's file (`SettingsController.fileRoot`) and the
    /// managed keys (`managedKeys` and `managedPolicy`, dotted), whose problems are not the person's.
    public mutating func update(_ diagnostics: [SettingsDiagnostic], file: JSONValue, managed: Set<String> = []) -> Update {
        var seen: Set<String> = []
        var pending: [Notice] = []
        for diagnostic in diagnostics where Self.announces(diagnostic.kind) && !Self.isManaged(diagnostic.path, managed) {
            let value = diagnostic.path.isEmpty ? nil : file.value(at: CmuxConfigFile.keyPath(from: diagnostic.path))?.compactText
            let notice = Notice(kind: diagnostic.kind, path: diagnostic.path, value: value, message: diagnostic.message)
            guard seen.insert(notice.fingerprint).inserted else { continue }
            if !remembered.contains(notice.fingerprint) { pending.append(notice) }
        }
        remembered.formIntersection(seen)
        let cleared = shown.map { !seen.contains($0) } ?? false
        if cleared { shown = nil }
        return Update(announce: pending, cleared: cleared)
    }

    /// Records that a toast showed `notices` (it names the first).
    public mutating func announced(_ notices: [Notice]) {
        guard let first = notices.first else { return }
        remembered.formUnion(notices.map(\.fingerprint))
        shown = first.fingerprint
    }

    /// A key a managed layer sets, inside one, or holding one.
    private static func isManaged(_ path: String, _ managed: Set<String>) -> Bool {
        guard !path.isEmpty else { return false }
        return managed.contains { $0 == path || path.hasPrefix($0 + ".") || $0.hasPrefix(path + ".") }
    }
}
