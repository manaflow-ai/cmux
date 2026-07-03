#if os(iOS)
import CmuxAgentChat

enum ChatTranscriptTableItem: Equatable {
    case loadingMore
    case historyTruncated
    case loadFailed
    case empty
    case initialLoading
    case row(ChatTranscriptRow)
    case typing
    case bottomAnchor

    var id: String {
        switch self {
        case .loadingMore:
            return "loading-more"
        case .historyTruncated:
            return "history-truncated"
        case .loadFailed:
            return "load-failed"
        case .empty:
            return "empty"
        case .initialLoading:
            return "initial-loading"
        case .row(let row):
            return row.id
        case .typing:
            return "typing"
        case .bottomAnchor:
            return "bottom-anchor"
        }
    }
}
#endif
