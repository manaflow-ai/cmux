import Foundation

/// One Amp session record as written by `cmux hooks amp`.
struct AmpHookSessionRecord: Decodable {
    var sessionId: String?
    var cwd: String?
    var startedAt: TimeInterval?
    var updatedAt: TimeInterval?
    var title: String?
    var launchCommand: AmpHookLaunchCommandRecord?
}
