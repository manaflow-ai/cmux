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
        /// The file the value came from when it is not cmux-next.json (a theme file), else nil.
        public let file: String?
        /// What ``remembered`` stores: the key, a digest of the value (never
        /// the value itself) and the reason. A file that does not parse is one
        /// notice whatever the parse error says, so an autosave that moves the
        /// error does not announce it again.
        public let fingerprint: String

        init(path: String, value: String?, message: String, file: String?, fingerprint: String) {
            self.path = path
            self.value = value
            self.message = message
            self.file = file
            self.fingerprint = fingerprint
        }

        public init(kind: SettingsDiagnostic.Kind = .invalidValue, path: String, value: String?, message: String, file: String? = nil) {
            self.path = path
            self.value = value
            self.message = message
            self.file = file
            var request: [String: JSONValue] = ["kind": .string(kind.rawValue), "path": .string(path), "message": .string(message)]
            if let value { request["value"] = .string(value) }
            if let file { request["file"] = .string(file) }
            fingerprint = SettingsRust.answer("notices.fingerprint", .object(request))["fingerprint"]?.stringValue ?? ""
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
        SettingsRust.answer("notices.announces", ["kind": .string(kind.rawValue)])["announces"]?.boolValue ?? false
    }

    /// Takes one load's diagnostics, the user's file (`SettingsController.fileRoot`) and the
    /// managed keys (`managedKeys` and `managedPolicy`, dotted), whose problems are not the person's.
    /// cmux-config `notices.update` decides.
    public mutating func update(_ diagnostics: [SettingsDiagnostic], file: JSONValue, managed: Set<String> = []) -> Update {
        var request: [String: JSONValue] = [
            "diagnostics": .array(diagnostics.map(\.wire)),
            "file": file,
            "managed": .array(managed.sorted().map(JSONValue.string)),
            "remembered": .array(remembered.sorted().map(JSONValue.string)),
        ]
        if let shown { request["shown"] = .string(shown) }
        // A failed call keeps the state as it was and announces nothing.
        guard let reply = try? SettingsRust.call("notices.update", .object(request)) else { return Update(announce: [], cleared: false) }
        remembered = Set(reply["remembered"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        shown = reply["shown"]?.stringValue
        let announce = (reply["announce"]?.arrayValue ?? []).compactMap { entry -> Notice? in
            guard let path = entry["path"]?.stringValue, let message = entry["message"]?.stringValue,
                  let fingerprint = entry["fingerprint"]?.stringValue else { return nil }
            return Notice(path: path, value: entry["value"]?.stringValue, message: message, file: entry["file"]?.stringValue,
                          fingerprint: fingerprint)
        }
        return Update(announce: announce, cleared: reply["cleared"]?.boolValue ?? false)
    }

    /// Records that a toast showed `notices` (it names the first).
    public mutating func announced(_ notices: [Notice]) {
        guard let first = notices.first else { return }
        remembered.formUnion(notices.map(\.fingerprint))
        shown = first.fingerprint
    }
}
