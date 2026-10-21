import Foundation
@preconcurrency import Sparkle

extension SPUUserUpdateState {
    /// A real state for tests: Sparkle's initializer is private, but the state decodes from a coder.
    static func forTests(stage: SPUUserUpdateStage = .notDownloaded, userInitiated: Bool = false) -> SPUUserUpdateState {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        archiver.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData),
              let state = SPUUserUpdateState(coder: unarchiver) else {
            preconditionFailure("SPUUserUpdateState no longer decodes from its coder keys")
        }
        return state
    }
}
