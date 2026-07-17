import CmuxAgentChat
import Foundation

/// Renderable states for one stat-driven artifact path.
enum ChatArtifactViewerState: Equatable {
    case loading
    case folder
    case image(data: Data)
    case pdf(fileURL: URL)
    case media(fileURL: URL)
    case quickLook(fileURL: URL)
    case text
    case markdown
    case binary(stat: ChatArtifactStat)
    case tooLarge(actualSize: Int64?, limit: Int64)
    case unsupportedMedia
    case fileMissing
    case macUnreachable
    case forbidden
}
