import AppKit
import CmuxNextActions
import CmuxNextFocusUI
import Foundation
import Testing

/// A key the New Tab key hold gives back (`NewTabInputBuffer.release`: the field's readiness, the hold's end, a new opening,
/// a creation that takes the keys) is the person's own key, typed before the hold ended. It goes on in no action's run,
/// whatever run ends the hold: a CLI's or a script's opening (whose view-change rule is not the person's), a menu pick
/// (whose mark would make the replayed key's focus change a menu pick), or Cmd-N's create task, which ends the hold in its
/// `defer`. Review of #36233: the limit fires detached there, but these other ends gave the keys back inside the ending
/// run's scope.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct NewTabHoldReplayScopeTests {
    /// The scopes the held keys were given back in.
    @MainActor private final class Seen {
        var scopes: [ActionRunScope?] = []
    }

    private static func key(_ character: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                                      isARepeat: false, keyCode: 0))
    }

    @Test func heldKeysAreGivenBackOutsideTheRunThatEndsTheHold() throws {
        let seen = Seen()
        let buffer = NewTabInputBuffer(began: .now, focusField: { true }, deliver: { _ in seen.scopes.append(ActionRunScope.current) })
        let (first, second) = (try Self.key("h"), try Self.key("i"))
        #expect(buffer.capture(first) && buffer.capture(second), "the hold did not take the keys")
        // A CLI run's opening ends the hold (a second Cmd-T, a creation taking the keys): the held keys go on in its turn.
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) { buffer.release() }
        try #require(seen.scopes.count == 2, "the hold gave back \(seen.scopes.count) of its 2 keys")
        #expect(seen.scopes.allSatisfy { $0 == nil }, "the held keys went on inside the run that ended the hold: \(seen.scopes)")
    }

    /// The same for the field's readiness (`drain`), which a menu pick's run can reach (its focus settle).
    @Test func heldKeysDrainedToTheFieldGoOnOutsideTheRunThatDrainsThem() throws {
        let seen = Seen()
        let buffer = NewTabInputBuffer(began: .now, focusField: { true }, deliver: { _ in seen.scopes.append(ActionRunScope.current) })
        let typed = try Self.key("h")
        #expect(buffer.capture(typed), "the hold did not take the key")
        buffer.acknowledge(buffer.token)
        let drained = ActionRunScope.$current.withValue(ActionRunScope(origin: .user, allowsViewChange: true, menuPick: true)) { buffer.drain() }
        #expect(drained, "the ready field did not take the held key")
        try #require(seen.scopes.count == 1, "the drain gave back \(seen.scopes.count) of its 1 key")
        #expect(seen.scopes[0] == nil, "the held key went on inside the run that drained it: \(String(describing: seen.scopes[0]))")
    }
}
