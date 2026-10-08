import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// RECOVERABLE-BY-DEFAULT for tab icons (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS):
/// a user's icon change offers one undo toast; its Undo sends the earlier icon
/// to the daemon and offers the redo; automation offers no undo.
@MainActor @Suite struct TabIconHistoryTests {
    final class Host {
        var updates: [FieldUpdate<String>] = []
        var tabGone = false
        var toasts: [(message: String, undo: @MainActor () -> Void)] = []
    }

    private func history(_ host: Host) -> TabIconHistory {
        TabIconHistory(apply: { id, update in
            guard !host.tabGone, id == "tab_1" else { return false }
            host.updates.append(update)
            return true
        }, offerUndo: { message, undo in host.toasts.append((message, undo)) })
    }

    @Test func aUserIconChangeOffersOneUndoAndItsUndoOffersTheRedo() {
        let host = Host(), history = history(host)
        history.change("tab_1", from: nil, to: "star.fill", origin: .user)
        #expect(host.updates == [.set("star.fill")])
        #expect(host.toasts.map(\.message) == [TabIconStrings.undoSet])

        host.toasts.last?.undo()
        #expect(host.updates == [.set("star.fill"), .clear])
        #expect(host.toasts.map(\.message) == [TabIconStrings.undoSet, TabIconStrings.undoRemove])

        host.toasts.last?.undo()
        #expect(host.updates == [.set("star.fill"), .clear, .set("star.fill")])
    }

    @Test func undoingARemoveBringsBackTheEarlierIcon() {
        let host = Host(), history = history(host)
        history.change("tab_1", from: "🚀", to: nil, origin: .user)
        #expect(host.toasts.map(\.message) == [TabIconStrings.undoRemove])
        host.toasts.last?.undo()
        #expect(host.updates == [.clear, .set("🚀")])
    }

    @Test func undoingAReplaceRestoresTheIconBefore() {
        let host = Host(), history = history(host)
        history.change("tab_1", from: "🚀", to: "hammer", origin: .user)
        host.toasts.last?.undo()
        #expect(host.updates == [.set("hammer"), .set("🚀")])
    }

    @Test func automationAndUnchangedIconsOfferNoUndo() {
        let host = Host(), history = history(host)
        for origin in ActionOrigin.allCases where origin != .user {
            history.change("tab_1", from: nil, to: "star", origin: origin)
        }
        history.change("tab_1", from: "star", to: "star", origin: .user)
        #expect(host.updates.count == ActionOrigin.allCases.count)
        #expect(host.toasts.isEmpty)
    }

    @Test func aGoneTabOffersNoUndo() {
        let host = Host(), history = history(host)
        host.tabGone = true
        history.change("tab_1", from: nil, to: "star", origin: .user)
        #expect(host.updates.isEmpty)
        #expect(host.toasts.isEmpty)
    }
}
