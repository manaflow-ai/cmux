#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI

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
