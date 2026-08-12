import CmuxAgentChat
import Foundation

/// Renderable states for one stat-driven artifact path.
enum ChatArtifactViewerState: Equatable, Sendable {
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
    /// The panel/session that authorized this file is no longer open.
    case notFound
    /// The Mac answered but its cmux predates this preview RPC.
    case unsupported
    /// The Mac's transfer service is temporarily unavailable.
    case unavailable
    /// The Mac answered with an unrecognized error; retryable, not connectivity.
    case failed(code: String?)
}
