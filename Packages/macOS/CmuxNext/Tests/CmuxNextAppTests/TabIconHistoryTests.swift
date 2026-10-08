import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// RECOVERABLE-BY-DEFAULT for icons (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS,
/// cx-k9go): a user's icon change offers one undo toast; its Undo sends the earlier icon
/// to the daemon and offers the redo; automation offers no undo.
@MainActor @Suite struct IconHistoryTests {
    final class Host {
        var updates: [FieldUpdate<String>] = []
        var tabGone = false
        var toasts: [(message: String, undo: @MainActor () -> Void)] = []
    }

    private func history(_ host: Host) -> IconHistory {
        IconHistory(messages: .tab, apply: { id, update in
            guard !host.tabGone, id == "tab_1" else { return false }
            host.updates.append(update)
            return true
        }, offerUndo: { message, undo in host.toasts.append((message, undo)) })
    }

    @Test func aUserIconChangeOffersOneUndoAndItsUndoOffersTheRedo() throws {
        let host = Host(), history = history(host)
        try history.change("tab_1", from: nil, to: "star.fill", origin: .user)
        #expect(host.updates == [.set("star.fill")])
        #expect(host.toasts.map(\.message) == [TabIconStrings.undoSet])

        host.toasts.last?.undo()
        #expect(host.updates == [.set("star.fill"), .clear])
        #expect(host.toasts.map(\.message) == [TabIconStrings.undoSet, TabIconStrings.undoRemove])

        host.toasts.last?.undo()
        #expect(host.updates == [.set("star.fill"), .clear, .set("star.fill")])
    }

    @Test func undoingARemoveBringsBackTheEarlierIcon() throws {
        let host = Host(), history = history(host)
        try history.change("tab_1", from: "🚀", to: nil, origin: .user)
        #expect(host.toasts.map(\.message) == [TabIconStrings.undoRemove])
        host.toasts.last?.undo()
        #expect(host.updates == [.clear, .set("🚀")])
    }

    @Test func undoingAReplaceRestoresTheIconBefore() throws {
        let host = Host(), history = history(host)
        try history.change("tab_1", from: "🚀", to: "hammer", origin: .user)
        host.toasts.last?.undo()
        #expect(host.updates == [.set("hammer"), .set("🚀")])
    }

    @Test func automationAndUnchangedIconsOfferNoUndo() throws {
        let host = Host(), history = history(host)
        for origin in ActionOrigin.allCases where origin != .user {
            try history.change("tab_1", from: nil, to: "star", origin: origin)
        }
        try history.change("tab_1", from: "star", to: "star", origin: .user)
        #expect(host.updates.count == ActionOrigin.allCases.count)
        #expect(host.toasts.isEmpty)
    }

    @Test func aGoneTabOffersNoUndo() throws {
        let host = Host(), history = history(host)
        host.tabGone = true
        try history.change("tab_1", from: nil, to: "star", origin: .user)
        #expect(host.updates.isEmpty)
        #expect(host.toasts.isEmpty)
    }
}
