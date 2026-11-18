import CryptoKit
import Foundation

/// The Cloud's ids for a Stack user and team (the Worker's `userIdFor` and `stackTeamIdFor`, the
/// Mac's `CloudIdentity.workerUserID` / `workerTeamID`): sha256 of the project and the Stack id,
/// its first 20 hex digits after `user_` / `team_`.
struct CloudIDs {
    static func user(project: String, stackUser: String) -> String {
        "user_" + hex("stack:\(project):\(stackUser)")
    }

    static func team(project: String, stackTeam: String) -> String {
        "team_" + hex("stack-team:\(project):\(stackTeam.lowercased())")
    }

    private static func hex(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
    }
}
