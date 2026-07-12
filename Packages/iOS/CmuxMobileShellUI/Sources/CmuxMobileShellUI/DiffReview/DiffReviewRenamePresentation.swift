import CmuxMobileRPC
import CmuxMobileSupport
import Foundation

struct DiffReviewRenamePresentation {
    let text: String

    init?(file: MobileWorkspaceDiffStatusResponse.File) {
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
