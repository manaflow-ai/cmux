import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation

/// A Cloud source connected to a fake daemon, leased for one account.
struct CloudSourceHarness {
    static let me = Participant(id: ParticipantID("local-user"), kind: .human, displayName: "Me")

    /// `attachmentCache`: a temporary directory by default (never the user's caches).
    static func connected(to daemon: FakeCloudDaemon, userID: String = "stack-user-1",
                          attachmentCache: URL = CloudSourceHarness.temporaryDirectory()) -> CloudHomeSource {
        let source = CloudHomeSource(me: me, attachmentCache: attachmentCache)
        source.configure(commands: daemon, link: ObjectIdentifier(daemon),
                         identity: CloudIdentity(stackUserID: userID, displayName: "Me", localID: me.id), leased: true)
        return source
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CmuxNextHomeEngineTests-\(UUID().uuidString)", isDirectory: true)
    }
}
