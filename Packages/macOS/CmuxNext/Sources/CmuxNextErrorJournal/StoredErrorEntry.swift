import Foundation

/// One line of a journal segment: an ``ErrorEntry`` and the redaction rules its text went through.
///
/// The stamp sits beside the entry's own keys (`redacted_by`), so a build without it reads the line
/// as a plain entry and a line without it (written before the stamp, or by such a build) reads as
/// stale. The journal re-redacts only stale lines when it opens (``ErrorJournal``).
struct StoredErrorEntry: Codable {
    var entry: ErrorEntry
    /// ``ErrorRedactor/rulesDigest`` of the redactor that wrote the line; nil for an unstamped line.
    var redaction: String?

    private enum Key: String, CodingKey {
        case redaction = "redacted_by"
    }

    init(entry: ErrorEntry, redaction: String?) {
        self.entry = entry
        self.redaction = redaction
    }

    init(from decoder: any Decoder) throws {
        entry = try ErrorEntry(from: decoder)
        redaction = try decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: .redaction)
    }

    func encode(to encoder: any Encoder) throws {
        try entry.encode(to: encoder)
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(redaction, forKey: .redaction)
    }
}
