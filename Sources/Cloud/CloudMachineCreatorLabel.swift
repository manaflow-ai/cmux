import CmuxCloud
import Foundation

/// How a Cloud machine's author reads on its row.
///
/// Its own file, away from the row content, for a dull reason worth writing
/// down: `scripts/localize-changes` cannot parse a `defaultValue` containing a
/// `\u{...}` escape, and `CloudTreeMachineRowContent` has several. A new string
/// added there is invisible to the tool, so it lives here where the tool can
/// see it.
struct CloudMachineCreatorLabel {
    /// Nil when there is nothing worth showing: no author, or an author whose
    /// name nobody has recorded. The account id is deliberately not a fallback.
    /// A row reading "by 7f3a91c2" is the same unreadable list of generated
    /// names this is meant to fix, with one more opaque token in it.
    static func text(creator: VMCreator?) -> String? {
        guard let name = creator?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return String(format: String(localized: "machines.row.createdBy", defaultValue: "by %@"), name)
    }
}
