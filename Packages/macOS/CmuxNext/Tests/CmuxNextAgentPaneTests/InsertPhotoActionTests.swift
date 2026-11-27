@testable import CmuxNextActions
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Insert Photo… (`insertPhoto`): the chosen pictures go into the focused pane. A chat takes the
/// files into its composer; a terminal gets their quoted paths pasted; a remote terminal needs a
/// path on its own machine; any other pane refuses. The panel is a closure here (no person clicks it).
@MainActor
struct InsertPhotoActionTests {
    private static let quote: @Sendable (String) -> String? = { $0.replacingOccurrences(of: " ", with: "\\ ") }

    /// The effect's work, run as the registry would; nil for an effect with no work.
    private func run(_ effect: ActionEffect) async -> (ran: Bool, failure: ActionWorkFailure?) {
        guard case .waiting(_, let work) = effect.kind else { return (false, nil) }
        return (true, await work())
    }

    private func refusal(_ effect: ActionEffect) -> String? {
        if case .refused(let reason, _) = effect.kind { return reason }
        return nil
    }

    @Test func aChatTakesTheChosenPicturesIntoItsComposer() async {
        var attached: [[URL]] = [], asked = 0
        let picked = [URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.heic")]
        let action = InsertPhotoAction(target: { _ in .chat(attach: { attached.append($0) }) },
                                       choose: { asked += 1; return picked }, shellQuoted: Self.quote)
        let (ran, failure) = await run(action.effect(for: ActionInvocation()))
        #expect(ran && failure == nil)
        #expect(asked == 1, "the panel opens once")
        #expect(attached == [picked], "the composer takes the pictures as picked")
    }

    @Test func cancelAttachesNothing() async {
        var attached = 0
        let action = InsertPhotoAction(target: { _ in .chat(attach: { _ in attached += 1 }) }, choose: { [] }, shellQuoted: Self.quote)
        _ = await run(action.effect(for: ActionInvocation()))
        #expect(attached == 0)
    }

    @Test func aPathArgumentSkipsThePanel() async {
        var attached: [[URL]] = [], asked = 0
        let action = InsertPhotoAction(target: { _ in .chat(attach: { attached.append($0) }) },
                                       choose: { asked += 1; return [] }, shellQuoted: Self.quote)
        let effect = action.effect(for: ActionInvocation(arguments: ["path": .string("/tmp/shot.png")]))
        if case .done = effect.kind {} else { Issue.record("a given path attaches on this turn") }
        #expect(asked == 0)
        #expect(attached == [[URL(fileURLWithPath: "/tmp/shot.png")]])
    }

    @Test func aTerminalGetsTheQuotedPathsPasted() async {
        var sent: [String] = []
        let action = InsertPhotoAction(target: { _ in .terminal(isLocal: true, send: { sent.append($0); return nil }) },
                                       choose: { [URL(fileURLWithPath: "/tmp/my shot.png"), URL(fileURLWithPath: "/tmp/b.jpg")] },
                                       shellQuoted: Self.quote)
        let (ran, failure) = await run(action.effect(for: ActionInvocation()))
        #expect(ran && failure == nil)
        #expect(sent == ["/tmp/my\\ shot.png /tmp/b.jpg"], "one paste: each path quoted, joined by a space")
    }

    @Test func noPathsOrAnUnquotablePathPasteNothing() {
        #expect(InsertPhotoAction.insertText(for: [], shellQuoted: Self.quote) == nil)
        #expect(InsertPhotoAction.insertText(for: [URL(fileURLWithPath: "/tmp/a")], shellQuoted: { _ in nil }) == nil,
                "a path that can't be quoted pastes nothing rather than a broken word")
    }

    @Test func aRemoteTerminalNeedsAPathOnItsMachine() async {
        var sent: [String] = [], asked = 0
        let action = InsertPhotoAction(target: { _ in .terminal(isLocal: false, send: { sent.append($0); return nil }) },
                                       choose: { asked += 1; return [] }, shellQuoted: Self.quote)
        #expect(refusal(action.effect(for: ActionInvocation())) == InsertPhotoAction.localOnly)
        #expect(asked == 0, "no panel for files the remote terminal could not read")
        _ = await run(action.effect(for: ActionInvocation(arguments: ["path": .string("/home/me/p.png")])))
        #expect(sent == ["/home/me/p.png"])
    }

    @Test func anotherPaneRefusesAndNoPaneDoesNothing() {
        let refused = InsertPhotoAction(target: { _ in .refused(InsertPhotoAction.noPictureTarget) }, choose: { [] }, shellQuoted: Self.quote)
        #expect(refusal(refused.effect(for: ActionInvocation())) == InsertPhotoAction.noPictureTarget)
        let none = InsertPhotoAction(target: { _ in nil }, choose: { [] }, shellQuoted: Self.quote)
        if case .done = none.effect(for: ActionInvocation()).kind {} else { Issue.record("no pane: nothing runs") }
    }

    @Test func theCatalogRowTakesAnOptionalPath() throws {
        // Until the app-ffi re-pin carries the row (cmux-action-catalog tests/awaiting-repin/actions/insertPhoto)
        // the pinned catalog has no insertPhoto; the re-pin's follow-up drops this guard.
        guard let descriptor = ActionCatalog.all.first(where: { $0.id == InsertPhotoAction.id }) else { return }
        #expect(descriptor.arguments.map(\.name) == ["path"])
        #expect(descriptor.arguments.map(\.isRequired) == [false])
        #expect(descriptor.isPaletteVisible)
    }
}
