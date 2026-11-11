import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// The one close-selection rule, through the app's own entry points (/work/wt/handoff/tasks/close-selection-rule.md
/// R1 and R2; Lawrence 2026-11-10: "tabs also follow Chrome's rule"). A person's new tab keeps the tab it came
/// from as its opener, so its close selects that tab again, whichever way the person closes it: Cmd-W, the close
/// button, a middle click, the tab menu, the palette's Close Tab, and also the CLI's close of it.
///
/// Both places of a new tab, because each one tells the rule from another pick:
/// - after the current tab (the default; Chrome's observed middle-tab rows): the pick by position is the NEXT tab;
/// - at the end (the quick look-up): the pick by position, and the old rule's "tab before", is the LAST tab left.
/// The opener is neither. Every entry point reaches the pane's one selection path (`TabSelectionMemory.resolve`);
/// a case here fails when an entry point picks on its own, or when the new tab's opener is not reported.
///
/// The palette's case runs the call its Close Tab row runs (`RegistryPaletteProvider`: the registry's `perform`
/// with a default invocation); no palette window is driven here.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabCloseEntryPointsTests {
    enum Entry: String, CaseIterable, Sendable { case cmdW, closeButton, middleClick, tabMenu, palette, cli }
    enum Place: String, CaseIterable, Sendable { case afterCurrent, atEnd }

    @Test(arguments: Entry.allCases, Place.allCases)
    func aPersonsNewTabClosedReturnsToTheTabItCameFrom(entry: Entry, place: Place) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await TabCloseSelectsBeforeTests.pane(services, connection, browsers: 3) // T b0 b1 b2
            let store = services.daemon.store
            let opener = ids[1]
            try await TabCloseSelectsBeforeTests.select(opener, in: pane)

            // The person's new tab, in a named place whatever the setting says.
            let action: ActionID = place == .afterCurrent ? "newTab.afterCurrent" : "newTab.atEnd"
            #expect(services.registry.perform(action, invocation: ActionInvocation(origin: .user)))
            @MainActor func made() -> TabModel? {
                (store.pane(pane.pane.handle)?.tabs ?? []).first { !ids.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }
            }
            @MainActor func wanted(_ new: String) -> [String] {
                place == .afterCurrent ? [ids[0], ids[1], new, ids[2], ids[3]] : ids + [new]
            }
            try await PinnedPageTests.until({
                guard let new = made()?.id else { return false }
                return pane.orderedIDs.map(\.rawValue) == wanted(new) && pane.stripModel.selectedID?.rawValue == new
            }, report: { "the new tab \(made()?.id ?? "none"): the pane holds \(pane.orderedIDs.map(\.rawValue)), selects \(pane.stripModel.selectedID?.rawValue ?? "none")" })
            let new = try #require(made())

            switch entry {
            case .cmdW: #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            case .closeButton: pane.stripModel.send(.close(TabID(new.id), source: .mouse))
            case .middleClick: pane.stripModel.send(.close(TabID(new.id), source: .middleClick))
            case .tabMenu: pane.stripModel.send(.close(TabID(new.id), source: .contextMenu))
            case .palette: #expect(services.registry.perform("closeTab", invocation: ActionInvocation()))
            case .cli: try await connection.closeTab(new.surface)
            }
            try await TabCloseSelectsBeforeTests.expect(pane, services, closed: [new.id], selects: opener,
                                                        "\(entry.rawValue), a new tab \(place.rawValue)")
        }
    }

    /// R3 of the rule file: a person's jump to an unrelated tab ends the opener of a new tab put after the current
    /// one, as a click on that tab does (Chrome's observed row: N from B, go to D, go to N, close N gives the next
    /// tab). The jump here is the call that tab search, a notification and a link to a tab make
    /// (`AppServices.revealTab`): it writes the window's selection itself, so the rule must hear of the gesture
    /// before that write. Without that, the close goes back to the opener.
    @Test func aPersonsJumpToAnUnrelatedTabEndsTheOpener() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await TabCloseSelectsBeforeTests.pane(services, connection, browsers: 3) // T b0 b1 b2
            let store = services.daemon.store
            try await TabCloseSelectsBeforeTests.select(ids[1], in: pane)
            #expect(services.registry.perform("newTab.afterCurrent", invocation: ActionInvocation(origin: .user)))
            @MainActor func made() -> TabModel? {
                (store.pane(pane.pane.handle)?.tabs ?? []).first { !ids.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }
            }
            try await PinnedPageTests.until({
                guard let new = made()?.id else { return false }
                return pane.orderedIDs.map(\.rawValue) == [ids[0], ids[1], new, ids[2], ids[3]] && pane.stripModel.selectedID?.rawValue == new
            }, report: { "the new tab \(made()?.id ?? "none"): the pane holds \(pane.orderedIDs.map(\.rawValue)), selects \(pane.stripModel.selectedID?.rawValue ?? "none")" })
            let new = try #require(made())

            // To b2 (no opener, not the new tab's opener) and back, each by the jump. No window is ordered in on the test host.
            services.showJumpWindow = { _, _ in }
            for jump in [ids[3], new.id] {
                #expect(services.revealTab(jump), "the jump to \(jump)")
                try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == jump },
                                                report: { "the jump to \(jump): the pane selects \(pane.stripModel.selectedID?.rawValue ?? "none")" })
            }
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await TabCloseSelectsBeforeTests.expect(pane, services, closed: [new.id], selects: ids[2],
                                                        "a new tab after b0, a jump to b2 and back, then Cmd-W: the next tab")
        }
    }
}
