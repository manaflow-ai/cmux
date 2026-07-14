import Foundation

/// A user-supplied worktree name normalized into a candidate local branch ref.
struct WorktreeSidebarBranchName: Equatable, Sendable {
    let value: String

    init?(userInput: String) {
        let scalars = userInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .unicodeScalars
        var result = ""
        var separatorPending = false

        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if separatorPending, !result.isEmpty, result.last != "-" {
                    result.append("-")
                }
                result.unicodeScalars.append(scalar)
                separatorPending = false
            } else if scalar == "." {
                if !separatorPending, !result.isEmpty, result.last != "." {
                    result.append(".")
                }
            } else {
                if result.last == "." {
                    result.removeLast()
                }
                separatorPending = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !trimmed.isEmpty else { return nil }
        value = trimmed
    }
}
