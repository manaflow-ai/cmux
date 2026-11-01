import CmuxNextCloud
import Foundation

/// What Share Machine… and Share with Me say (CloudMachineShare.swift). Keys live in
/// Resources/CloudShare.xcstrings with every app locale.
enum CloudShareStrings {
    /// The page's title: "Share build-box".
    static func pageTitle(_ machine: String) -> String {
        String(format: String(localized: "cloud.share.pageTitle", defaultValue: "Share %@", table: "CloudShare", bundle: .module), machine)
    }

    static var placeholder: String { String(localized: "cloud.share.placeholder", defaultValue: "Search teammates", table: "CloudShare", bundle: .module) }
    /// A shared row's subtitle.
    static var canStartChats: String { String(localized: "cloud.share.canStartChats", defaultValue: "Can start chats", table: "CloudShare", bundle: .module) }
    static var share: String { String(localized: "cloud.share.share", defaultValue: "Share", table: "CloudShare", bundle: .module) }
    static var stopSharing: String { String(localized: "cloud.share.stopSharing", defaultValue: "Stop Sharing", table: "CloudShare", bundle: .module) }
    /// The CLI answer's title.
    static var listTitle: String { String(localized: "cloud.share.listTitle", defaultValue: "Shared With", table: "CloudShare", bundle: .module) }
    static var noTeam: String { String(localized: "cloud.share.noTeam", defaultValue: "Sharing a machine needs a team. Pick your team in Settings > Accounts.", table: "CloudShare", bundle: .module) }
    static var notCloudMachine: String { String(localized: "cloud.share.notCloudMachine", defaultValue: "This chat's machine is not a cmux Cloud machine, so it has nothing to share.", table: "CloudShare", bundle: .module) }

    /// The toast after a share: "Ada can start chats on build-box."
    static func shared(_ teammate: String, _ machine: String) -> String {
        String(format: String(localized: "cloud.share.shared", defaultValue: "%1$@ can start chats on %2$@.", table: "CloudShare", bundle: .module), teammate, machine)
    }

    /// The toast after a share was taken back.
    static func stopped(_ teammate: String, _ machine: String) -> String {
        String(format: String(localized: "cloud.share.stopped", defaultValue: "%1$@ can no longer start chats on %2$@.", table: "CloudShare", bundle: .module), teammate, machine)
    }

    static func refusal(_ refusal: CloudMachineShareRefusal) -> String {
        switch refusal {
        case .forbidden: String(localized: "cloud.share.forbidden", defaultValue: "Only the machine's creator or a team admin can share it.", table: "CloudShare", bundle: .module)
        case .personalMachine: String(localized: "cloud.share.personalMachine", defaultValue: "This machine is on a personal account, so only its creator can start chats on it.", table: "CloudShare", bundle: .module)
        case .unavailable: String(localized: "cloud.share.unavailable", defaultValue: "Machine sharing is unavailable right now. Try again in a moment.", table: "CloudShare", bundle: .module)
        case .notMember: String(localized: "cloud.share.notMember", defaultValue: "Only a current member of this machine's team can be given chats on it.", table: "CloudShare", bundle: .module)
        }
    }
}
