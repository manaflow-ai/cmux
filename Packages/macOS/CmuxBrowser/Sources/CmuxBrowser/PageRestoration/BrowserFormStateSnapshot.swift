public import Foundation

/// Unsaved input in the main frame's form controls, reported by the injected
/// form-state observer.
///
/// WebKit's `interactionState` only carries form values for history entries
/// the user navigated away from, so the current page's typed input would be
/// lost when a discarded pane restores. This snapshot fills that gap. It is
/// kept in memory only and never written to the session file. Password,
/// payment, one-time-code and `autocomplete="off"` fields are never reported;
/// a change to one only sets ``hasUnrestorableInput``.
public struct BrowserFormStateSnapshot: Equatable, Sendable {
    /// Largest number of fields kept per document.
    public static let maxFieldCount = 200
    /// Largest value, in UTF-16 code units, kept per field.
    public static let maxValueLength = 64 * 1024

    public struct Field: Equatable, Sendable {
        /// Stable locator for the control: `id:`, `name:` or `path:` prefixed.
        public var key: String
        /// Text value for text-like inputs and text areas.
        public var value: String?
        /// Checked state for checkboxes and radio buttons.
        public var isChecked: Bool?
        /// Selected option indexes for select elements.
        public var selectedOptionIndexes: [Int]?

        public init(key: String, value: String? = nil, isChecked: Bool? = nil, selectedOptionIndexes: [Int]? = nil) {
            self.key = key
            self.value = value
            self.isChecked = isChecked
            self.selectedOptionIndexes = selectedOptionIndexes
        }
    }

    /// URL of the document the fields belong to.
    public var documentURL: URL
    public var fields: [Field]
    /// Whether the document also holds typed input a restore cannot replay,
    /// such as a password, a file selection or a rich-text edit.
    public var hasUnrestorableInput: Bool

    public init(documentURL: URL, fields: [Field], hasUnrestorableInput: Bool = false) {
        self.documentURL = documentURL
        self.fields = fields
        self.hasUnrestorableInput = hasUnrestorableInput
    }

    /// Parses `{ url, fields: [{ k, v?, c?, s? }], unrestorable? }` from the
    /// observer. Returns nil for a malformed body. Oversized values and fields
    /// past ``maxFieldCount`` are dropped and count as unrestorable input.
    public init?(messageBody: Any) {
        guard let body = messageBody as? [String: Any],
              let urlString = body["url"] as? String,
              let documentURL = URL(string: urlString),
              let rawFields = body["fields"] as? [Any] else {
            return nil
        }
        var fields: [Field] = []
        var hasUnrestorableInput = body["unrestorable"] as? Bool ?? false
        for rawField in rawFields {
            guard fields.count < Self.maxFieldCount else {
                hasUnrestorableInput = true
                break
            }
            guard let entry = rawField as? [String: Any],
                  let key = entry["k"] as? String,
                  !key.isEmpty else { continue }
            let field: Field
            if let value = entry["v"] as? String {
                guard value.utf16.count <= Self.maxValueLength else {
                    hasUnrestorableInput = true
                    continue
                }
                field = Field(key: key, value: value)
            } else if let checked = entry["c"] as? Bool {
                field = Field(key: key, isChecked: checked)
            } else if let selected = entry["s"] as? [Any] {
                let indexes = selected.compactMap { ($0 as? NSNumber)?.intValue }
                guard indexes.count == selected.count else {
                    hasUnrestorableInput = true
                    continue
                }
                field = Field(key: key, selectedOptionIndexes: indexes)
            } else {
                continue
            }
            fields.append(field)
        }
        self.init(documentURL: documentURL, fields: fields, hasUnrestorableInput: hasUnrestorableInput)
    }

    /// Whether there are no fields to restore.
    public var isEmpty: Bool { fields.isEmpty }

    /// Whether the fields were typed on the same origin as `url`. Values are
    /// never carried to another site. The report URL can trail the document
    /// URL after a same-document route change, so paths are not compared,
    /// except for file URLs, whose origin is the file itself.
    public func sharesOrigin(with url: URL?) -> Bool {
        guard let url else { return false }
        if documentURL.isFileURL || url.isFileURL {
            return documentURL.isFileURL && url.isFileURL && Self.isSameDocument(documentURL, url)
        }
        guard let scheme = documentURL.scheme?.lowercased(), let host = documentURL.host?.lowercased() else {
            return false
        }
        guard scheme == url.scheme?.lowercased(), host == url.host?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        return (documentURL.port ?? defaultPort) == (url.port ?? defaultPort)
    }

    /// Whether two URLs load the same document. Fragment changes keep the
    /// same document, so they are ignored.
    public static func isSameDocument(_ lhs: URL, _ rhs: URL) -> Bool {
        documentIdentity(lhs) == documentIdentity(rhs)
    }

    /// Fields in the shape the restore script expects as its `fields` argument.
    public var restorePayload: [[String: Any]] {
        fields.map { field in
            var entry: [String: Any] = ["k": field.key]
            if let value = field.value {
                entry["v"] = value
            } else if let isChecked = field.isChecked {
                entry["c"] = isChecked
            } else if let selectedOptionIndexes = field.selectedOptionIndexes {
                entry["s"] = selectedOptionIndexes
            }
            return entry
        }
    }

    static func documentIdentity(_ url: URL) -> String {
        if url.isFileURL {
            let standardized = url.standardizedFileURL
            let host = url.host?.lowercased() ?? ""
            let port = url.port.map(String.init) ?? ""
            return "\(host):\(port):\(standardized.path)"
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
