import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Share with Guest's refusals and notices (Resources/AgentShare.xcstrings).
enum AgentShareStrings {
    static var notAChat: String {
        String(localized: "agentShare.notAChat", defaultValue: "Only a started agent chat can be shared.", table: "AgentShare", bundle: .module)
    }

    static var notThisMac: String {
        String(localized: "agentShare.notThisMac", defaultValue: "Only a chat on this Mac can be shared.", table: "AgentShare", bundle: .module)
    }

    static var badSurface: String {
        String(localized: "agentShare.badSurface", defaultValue: "--surface takes a surface number.", table: "AgentShare", bundle: .module)
    }

    static var surfaceAndTarget: String {
        String(localized: "agentShare.surfaceAndTarget", defaultValue: "Name the chat with --surface or with a tab target, not both.", table: "AgentShare", bundle: .module)
    }

    static var badUses: String {
        String(localized: "agentShare.badUses", defaultValue: "--uses takes a number from 1 to 8.", table: "AgentShare", bundle: .module)
    }

    static var timedOut: String {
        String(localized: "agentShare.timedOut", defaultValue: "The share service didn’t answer in time, so no link was made. Try again.", table: "AgentShare", bundle: .module)
    }

    static func noSurface(_ surface: Int) -> String {
        String(format: String(localized: "agentShare.noSurface", defaultValue: "No agent chat is on surface %lld.", table: "AgentShare", bundle: .module), Int64(surface))
    }

    static var badTTL: String {
        String(localized: "agentShare.badTTL", defaultValue: "A link lasts from 1 minute to 7 days: give seconds, or a number with m, h or d (24h).", table: "AgentShare", bundle: .module)
    }

    static var needsShareID: String {
        String(localized: "agentShare.needsShareID", defaultValue: "Name the link's share ID (cmux share list shows it).", table: "AgentShare", bundle: .module)
    }

    static var needsGuestID: String {
        String(localized: "agentShare.needsGuestID", defaultValue: "Name the guest's ID (cmux share list shows it).", table: "AgentShare", bundle: .module)
    }

    static var copied: String {
        String(localized: "agentShare.copied", defaultValue: "Guest link copied. It works once and expires in 24 hours.", table: "AgentShare", bundle: .module)
    }

    static var noRoom: String {
        String(localized: "agentShare.noRoom", defaultValue: "The link was made, but this cmux has no share service to open it.", table: "AgentShare", bundle: .module)
    }

    /// A person's sentence for the daemon's `share.*` refusal; nil keeps the daemon's message.
    static func reason(_ code: String) -> String? {
        switch code {
        case "share.needs_sign_in": String(localized: "agentShare.needsSignIn", defaultValue: "Sign in to cmux to share a chat.", table: "AgentShare", bundle: .module)
        case "share.room_unreachable": String(localized: "agentShare.roomUnreachable", defaultValue: "The share service didn’t answer. Try again in a moment.", table: "AgentShare", bundle: .module)
        case "share.room_refused": String(localized: "agentShare.roomRefused", defaultValue: "Sharing is off for this account.", table: "AgentShare", bundle: .module)
        case "share.not_a_chat": notAChat
        case "share.chat_moved": String(localized: "agentShare.chatMoved", defaultValue: "That surface shows another chat now. Name the chat again.", table: "AgentShare", bundle: .module)
        case "share.limit": String(localized: "agentShare.limit", defaultValue: "This Mac has too many links. Revoke one first.", table: "AgentShare", bundle: .module)
        case "share.unknown": String(localized: "agentShare.unknown", defaultValue: "No such link or guest.", table: "AgentShare", bundle: .module)
        case "share.not_trusted": String(localized: "agentShare.notTrusted", defaultValue: "Only chats on this Mac can be shared.", table: "AgentShare", bundle: .module)
        case "share.bad_request": String(localized: "agentShare.badRequest", defaultValue: "A link works 1 to 8 times and lasts from 1 minute to 7 days.", table: "AgentShare", bundle: .module)
        default: nil
        }
    }

    /// A share verb's failure for its caller: the daemon's `share.*` code (the CLI and MCP see it as
    /// the error code) with a sentence a person can act on.
    static func failure(_ error: any Error) -> ActionWorkFailure {
        // No answer in time: the daemon may still make (or provision) the share, so the caller is
        // told the run may have applied and must not simply retry.
        if case DaemonError.timedOut = error {
            return ActionWorkFailure(timedOut, mayHaveApplied: true)
        }
        guard case DaemonError.command(_, let message, let code?, _, _) = error, code.hasPrefix("share.") else {
            return ActionWorkFailure(RefusalStrings.describe(error))
        }
        return ActionWorkFailure(code: code, reason: reason(code) ?? message)
    }
}
