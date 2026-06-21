import Foundation

struct CodexTeamsAppServerRequestError: Error, CustomStringConvertible {
    let code: Int?
    let message: String

    var description: String { message }

    var isMissingRollout: Bool {
        message.localizedCaseInsensitiveContains("no rollout found for thread id")
    }
}
