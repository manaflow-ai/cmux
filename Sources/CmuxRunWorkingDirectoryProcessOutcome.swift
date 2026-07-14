import Foundation

enum CmuxRunWorkingDirectoryProcessOutcome: Sendable {
    case completed(status: Int32, output: Data)
    case timedOut
}
