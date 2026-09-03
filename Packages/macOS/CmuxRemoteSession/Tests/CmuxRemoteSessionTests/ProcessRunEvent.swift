import Foundation
@testable import CmuxRemoteSession

enum ProcessRunEvent: Sendable {
    case completed(Result<RemoteCommandResult, any Error>)
    case deadline
}
