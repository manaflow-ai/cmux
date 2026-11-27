import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

extension HomeService {
    /// The local mux participant every local conversation starts with.
    static let mux = DaemonHomeSource.chief

    /// The local user as a participant, named after the macOS account.
    static var localUser: ConversationParticipant {
        ConversationParticipant(id: ConversationParticipant.localUserID, kind: .human, displayName: HomeChiefName.localUserName)
    }
}
