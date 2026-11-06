import Foundation

extension CloudMachine {
    /// The name a new machine gets when the person typed none: `base` ("Cloud Machine") when no
    /// machine in `taken` has that title, else the first free `numbered(n)` from 2 ("Cloud Machine 2").
    /// Titles compare trimmed and case-insensitively, so a renamed "cloud machine" still counts.
    public static func defaultName(taken: some Sequence<String>, base: String, numbered: (Int) -> String) -> String {
        let used = Set(taken.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let free: (String) -> Bool = { !used.contains($0.lowercased()) }
        if free(base) { return base }
        var number = 2
        while !free(numbered(number)) { number += 1 }
        return numbered(number)
    }
}
