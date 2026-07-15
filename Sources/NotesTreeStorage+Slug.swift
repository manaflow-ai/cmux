import Foundation

extension NotesTreeStorage {
    /// Lowercase, hyphen-joined slug of `value`; `fallback` when empty.
    static func slugify(_ value: String, fallback: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = String(trimmed.prefix(48))
        return capped.isEmpty ? fallback : capped
    }
}
