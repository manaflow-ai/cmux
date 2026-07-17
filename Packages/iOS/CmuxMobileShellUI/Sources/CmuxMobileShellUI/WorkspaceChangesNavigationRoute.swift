#if os(iOS)
import CmuxMobileChanges

enum WorkspaceChangesNavigationRoute: Hashable {
    case diff(Int)
    case preview(index: Int, revision: FileDiffPreviewRevision)
}
#endif
