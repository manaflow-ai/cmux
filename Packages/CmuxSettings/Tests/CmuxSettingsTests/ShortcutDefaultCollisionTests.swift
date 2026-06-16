import Foundation
import Testing
@testable import CmuxSettings

@Suite("ShortcutDefaultCollision")
struct ShortcutDefaultCollisionTests {
    /// Factory-default shortcut pairs that intentionally share a chord and are
    /// resolved at runtime rather than by `when`-context, so context-aware
    /// collision detection legitimately reports them as overlapping.
    ///
    /// - `groupSelectedWorkspaces` ⇄ `toggleReactGrab` (⌘⇧G): both ship
    ///   `.application`-scoped, but the group handler propagates the event
    ///   (returns `false`) when there are no eligible workspaces to group, so
    ///   React Grab still fires where grouping would have been a no-op. The
    ///   overlap is documented in the app target's default-shortcut table
    ///   (`KeyboardShortcutSettings.swift`).
    static let intentionalOverlaps: Set<Set<ShortcutAction>> = [
        [.groupSelectedWorkspaces, .toggleReactGrab],
    ]

    /// Every chord that two actions share by default must be resolvable: either
    /// their effective `when`-contexts are disjoint (so the same keystroke drives
    /// each action in a different focus) or router priority picks a deterministic
    /// winner. Anything else is a shipped conflict — one action shadows the other
    /// and the duplicate is unreachable. Guards against re-introducing the class
    /// of bug behind #3467 and #5810.
    @Test func factoryDefaultsOnlyCollideWhereIntentional() {
        var actionsBySharedChord: [StoredShortcut: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            guard let shortcut = action.defaultShortcut else { continue }
            actionsBySharedChord[shortcut, default: []].append(action)
        }

        var collisions: Set<Set<ShortcutAction>> = []
        for actions in actionsBySharedChord.values where actions.count > 1 {
            for i in actions.indices {
                for j in actions.indices where j > i {
                    let lhs = actions[i]
                    let rhs = actions[j]
                    if ShortcutWhenClause.bindingsCollide(
                        lhs.defaultFocusWhenClause, lhsHasPriority: lhs.hasPriorityShortcutRouting,
                        rhs.defaultFocusWhenClause, rhsHasPriority: rhs.hasPriorityShortcutRouting
                    ) {
                        collisions.insert([lhs, rhs])
                    }
                }
            }
        }

        let unexpected = collisions.subtracting(Self.intentionalOverlaps)
        #expect(
            unexpected.isEmpty,
            "factory default shortcuts collide outside the intentional allowlist: \(unexpected)"
        )
        // The allowlist must not rot: an entry that no longer collides (e.g. one
        // side was rebound or re-scoped) should be removed so the list keeps
        // meaning every pair it names.
        let staleAllowlistEntries = Self.intentionalOverlaps.subtracting(collisions)
        #expect(
            staleAllowlistEntries.isEmpty,
            "intentional-overlap allowlist names pairs that no longer collide: \(staleAllowlistEntries)"
        )
    }

    /// `⌘[` / `⌘]` are the browser pane's Back / Forward. Workspace focus-history
    /// navigation binds the same chords, so it must yield to the browser while a
    /// browser panel is focused instead of double-firing; outside a browser it
    /// still navigates focus history.
    @Test func focusHistoryNavigationYieldsToBrowserBackForward() {
        for action in [ShortcutAction.focusHistoryBack, .focusHistoryForward] {
            let clause = action.defaultFocusWhenClause
            #expect(!clause.evaluate(ShortcutFocusState(browser: true, markdown: false, sidebar: false)))
            #expect(clause.evaluate(ShortcutFocusState(browser: false, markdown: false, sidebar: false)))
        }
    }
}
