import CmuxNextAgentPane
@testable import CmuxNextComputerUsePreview
import CmuxNextDaemon
import Testing

/// The App reads the daemon's `computer-use-preview` card into each surface's card: the agent chat's
/// (``AgentPaneComputerUsePreview``) and the terminal pane's, with the agent's cursor and done state.
@MainActor
struct ComputerUsePreviewRouterTests {
    static let card: [String: JSONValue] = [
        "session": .string("chat-1"), "label": .string("Codex"), "app": .string("Notes"), "done": .bool(false),
        "frame": .string("data:image/jpeg;base64,AA=="),
        "pointer": .object(["x": .number(0.25), "y": .number(0.5), "click": .number(4), "windowWidth": .number(800)]),
    ]

    @Test func aRunningCardReachesTheChatWithItsPointer() throws {
        let preview = try #require(ComputerUsePreviewRouter.chatCard(Self.card))
        #expect(preview.session == "chat-1" && preview.app == "Notes" && !preview.done)
        #expect(preview.frame == "data:image/jpeg;base64,AA==")
        #expect(preview.pointer == .init(x: 0.25, y: 0.5, click: 4, windowWidth: 800))
    }

    @Test func aDoneCardReachesTheTerminal() throws {
        var done = Self.card
        done["done"] = .bool(true)
        done["session"] = .string("terminal:t1:9")
        let card = try #require(ComputerUsePreviewRouter.terminalCard(done))
        #expect(card.done && card.session == "terminal:t1:9" && card.clicks == 4)
        #expect(ComputerUsePreviewRouter.chatCard(nil) == nil)
        #expect(ComputerUsePreviewRouter.terminalCard(["session": .string("s")]) == nil)
    }

    /// The daemon keeps where each card sits and whether it is hidden: the router reads both into
    /// the chat's and the terminal's card, and a hidden card from such a daemon still reaches its
    /// surface (as the chip that brings it back).
    @Test func theDaemonsPlaceAndHiddenFlagReachBothCards() throws {
        var placed = Self.card
        placed["place"] = .object(["x": .number(0.25), "y": .number(1), "size": .string("full")])
        placed["hidden"] = .bool(true)
        let chat = try #require(ComputerUsePreviewRouter.chatCard(placed))
        #expect(chat.place == .init(x: 0.25, y: 1, size: .full) && chat.hidden)
        let terminal = try #require(ComputerUsePreviewRouter.terminalCard(placed))
        #expect(terminal.place == .init(x: 0.25, y: 1, size: .full) && terminal.hidden)
        var odd = Self.card
        odd["place"] = .object(["x": .number(0.5), "y": .number(0.5), "size": .string("huge")])
        #expect(ComputerUsePreviewRouter.chatCard(odd)?.place == .init(x: 0.5, y: 0.5, size: .small))
        #expect(ComputerUsePreviewRouter.chatCard(Self.card)?.place == nil)
    }

    @Test func aMoveFromThePageGoesToTheDaemonAsItsChangesOnly() {
        #expect(ComputerUsePreviewRouter.update(.init(x: 0, y: 0.5)) == ["x": .number(0), "y": .number(0.5)])
        #expect(ComputerUsePreviewRouter.update(.init(size: .large)) == ["size": .string("large")])
    }

    /// A surface shows one card: an older session's card going (the hub drops old done cards) or
    /// turning done leaves the newer session's card alone. Live, an old session's `card: null` took
    /// a newer session's done card off its terminal.
    @Test func anOlderSessionsLineLeavesTheShownCardAlone() {
        let router = ComputerUsePreviewRouter(chat: { _ in nil }, terminal: { _ in nil })
        #expect(router.applies("old", running: true, to: "terminal:t1"))
        #expect(router.applies("new", running: true, to: "terminal:t1"))
        #expect(!router.applies("old", running: false, to: "terminal:t1"))
        #expect(router.applies("new", running: false, to: "terminal:t1"))
        #expect(router.applies("other", running: false, to: "terminal:t2"))
    }
}
