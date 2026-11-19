import CmuxMobileModel
import Foundation

/// One account's part of `KeptTerminalChats`: its kept pairings and each tab's face, keyed by
/// account and Mac. The live backend reads them through it (`MultiMacWorkspaceBackend`), and mock
/// mode is given one over the same file, so both run the same reads and writes.
@MainActor
public final class AccountKeptTerminalChats: TerminalChatKeeping {
    public let kept: KeptTerminalChats
    public let account: String

    public init(kept: KeptTerminalChats, account: String) {
        self.kept = kept
        self.account = account
    }

    public func keptTerminalChat(harness: String, session: String, on macID: String) -> String? {
        KeptTerminalChats.key(account, macID, harness, session).flatMap { kept.chat($0) }
    }
    public func keepTerminalChat(_ chat: String?, harness: String, session: String, on macID: String) {
        guard let key = KeptTerminalChats.key(account, macID, harness, session) else { return }
        kept.keepChat(chat, for: key)
    }
    public func keptTerminalChatFace(tabID: String, on macID: String) -> Bool? {
        KeptTerminalChats.key(account, macID, tabID).flatMap { kept.showsChat($0) }
    }
    public func keepTerminalChatFace(_ showsChat: Bool, tabID: String, on macID: String) {
        guard let key = KeptTerminalChats.key(account, macID, tabID) else { return }
        kept.keepFace(showsChat: showsChat, for: key)
    }
    public var keptTerminalChatsLoaded: Bool { kept.isLoaded }
    public func loadKeptTerminalChats() async { await kept.load() }
}
