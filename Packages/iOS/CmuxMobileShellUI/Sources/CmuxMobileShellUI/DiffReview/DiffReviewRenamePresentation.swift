import CmuxDiffModel
import CmuxMobileSupport
import Foundation

struct DiffReviewRenamePresentation {
    let text: String

    init?(file: DiffFileSummary) {
        guard let oldPath = file.oldPath else { return nil }
        text = String(
            format: L10n.string(
                "mobile.diff.renameFormat",
                defaultValue: "%@ → %@"
            ),
            oldPath,
            file.path
        )
    }
}
