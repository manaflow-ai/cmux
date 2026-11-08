#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI

struct TerminalArtifactGalleryItemValue: Equatable {
    let artifact: TerminalArtifactGalleryDisplayItem
    let layout: TerminalArtifactGalleryItemView.Layout
    let loaderScope: ChatArtifactLoaderScope
    let loaderSupportsArtifacts: Bool
    let loaderSupportsDirectoryBrowsing: Bool
    let openScope: TerminalArtifactFilesSheet.Scope
    let swipeOrder: ChatArtifactGallerySwipeOrder
}
#endif
