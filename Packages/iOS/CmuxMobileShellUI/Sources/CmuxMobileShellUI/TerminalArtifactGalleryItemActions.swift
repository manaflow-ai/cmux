#if os(iOS)
import CmuxArtifactCore
import CmuxArtifactUI

struct TerminalArtifactGalleryItemActions {
    let loader: ChatArtifactLoader
    let open: (
        String,
        TerminalArtifactFilesSheet.Scope,
        ChatArtifactGallerySwipeOrder
    ) -> Void
    let copiedPath: () -> Void
}
#endif
