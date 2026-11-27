import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("ToolbarItemID")
struct ToolbarItemIDTests {
    @Test("built-in storage key round-trips")
    func builtinRoundTrip() {
        let id = ToolbarItemID.builtin(7)
        #expect(id.storageKey == "builtin.7")
        #expect(ToolbarItemID(storageKey: "builtin.7") == id)
    }

    @Test("custom storage key round-trips")
    func customRoundTrip() {
        let uuid = UUID()
        let id = ToolbarItemID.custom(uuid)
        #expect(id.storageKey == "custom.\(uuid.uuidString)")
        #expect(ToolbarItemID(storageKey: "custom.\(uuid.uuidString)") == id)
    }

    @Test("malformed storage keys decode to nil")
    func malformed() {
        #expect(ToolbarItemID(storageKey: "builtin.notanint") == nil)
        #expect(ToolbarItemID(storageKey: "custom.not-a-uuid") == nil)
        #expect(ToolbarItemID(storageKey: "garbage") == nil)
        #expect(ToolbarItemID(storageKey: "") == nil)
    }

    @Test("Codable round-trips both cases")
    func codable() throws {
        let ids: [ToolbarItemID] = [.builtin(3), .custom(UUID())]
        let data = try JSONEncoder().encode(ids)
        let decoded = try JSONDecoder().decode([ToolbarItemID].self, from: data)
        #expect(decoded == ids)
    }
}

@Suite("TerminalAccessoryLayoutReducer over ToolbarItemID")
struct ToolbarItemReducerTests {
    private func makeReducer(custom: [UUID]) -> TerminalAccessoryLayoutReducer<ToolbarItemID> {
        let builtins: [ToolbarItemID] = [.builtin(0), .builtin(1)]
        let customs = custom.map { ToolbarItemID.custom($0) }
        return TerminalAccessoryLayoutReducer(configurable: builtins + customs)
    }

    @Test("mixed built-in and custom order is preserved, new custom appends")
    func mixedOrder() {
        let a = UUID(), b = UUID()
        let reducer = makeReducer(custom: [a, b])
        // Saved layout only knew about builtin.1 and custom a; builtin.0 and
        // custom b were added in a later edit and must append in canonical order.
        let layout = reducer.load(
            savedOrder: [.builtin(1), .custom(a)],
            savedEnabled: [.builtin(1), .custom(a)]
        )
        #expect(layout.order == [.builtin(1), .custom(a), .builtin(0), .custom(b)])
        #expect(layout.visibleOrder == [.builtin(1), .custom(a)])
    }

    @Test("deleting a custom drops its identifier on next load")
    func dropsDeletedCustom() {
        let a = UUID(), gone = UUID()
        // Reducer no longer lists `gone` (the user deleted that custom action).
        let reducer = makeReducer(custom: [a])
        let layout = reducer.load(
            savedOrder: [.custom(gone), .custom(a), .builtin(0)],
            savedEnabled: [.custom(gone), .custom(a)]
        )
        #expect(layout.order == [.custom(a), .builtin(0), .builtin(1)])
        #expect(layout.enabled == Set([.custom(a)]))
    }
}

@Suite("ToolbarLayoutMigration")
struct ToolbarLayoutMigrationTests {
    private let migration = ToolbarLayoutMigration()

    @Test("legacy order relabels to built-in identifiers, preserving order")
    func order() {
        #expect(migration.migratedOrder(legacy: [2, 0, 5]) == [.builtin(2), .builtin(0), .builtin(5)])
    }

    @Test("nil enabled stays nil (first launch); empty stays empty (user hid all)")
    func enabledNuance() {
        #expect(migration.migratedEnabled(legacy: nil) == nil)
        #expect(migration.migratedEnabled(legacy: []) == [])
        #expect(migration.migratedEnabled(legacy: [1, 3]) == [.builtin(1), .builtin(3)])
    }

    @Test("migrated layout preserves the user's existing order and hidden set")
    func preservesExistingArrangement() {
        // A v1 user reordered to [3, 1, 0, 2] and hid action 2.
        let reducer = TerminalAccessoryLayoutReducer<ToolbarItemID>(
            configurable: [0, 1, 2, 3].map { .builtin($0) }
        )
        let layout = reducer.load(
            savedOrder: migration.migratedOrder(legacy: [3, 1, 0, 2]),
            savedEnabled: migration.migratedEnabled(legacy: [3, 1, 0])
        )
        #expect(layout.order == [.builtin(3), .builtin(1), .builtin(0), .builtin(2)])
        #expect(layout.visibleOrder == [.builtin(3), .builtin(1), .builtin(0)])
    }
}

@Suite("ToolbarLayoutMigration v3 widening")
struct ToolbarLayoutMigrationV3Tests {
    private let migration = ToolbarLayoutMigration()
    // Mirrors the real action rawValues: control=0, alternate=1, command=2 pinned
    // leading; zoomOut=4, zoomIn=5 pinned trailing; tab=7, escape=6 are shortcuts.
    private let forcedLeading = [0, 1, 2]
    private let forcedTrailing = [4, 5]

    @Test("forced built-ins are inserted at front/back and force-enabled")
    func insertsAndEnablesForcedBuiltins() {
        // A v2 user had only the trailing shortcuts (tab, escape) configured.
        let widened = migration.widenedToV3(
            order: [.builtin(7), .builtin(6)],
            enabled: [.builtin(7), .builtin(6)],
            forcedLeading: forcedLeading,
            forcedTrailing: forcedTrailing
        )
        #expect(widened.order == [
            .builtin(0), .builtin(1), .builtin(2), // leading modifiers prepended
            .builtin(7), .builtin(6),              // saved shortcuts unchanged
            .builtin(4), .builtin(5),              // trailing zoom appended
        ])
        // Modifiers/zoom are force-shown alongside the user's existing shown set.
        #expect(Set(widened.enabled) == Set([
            .builtin(0), .builtin(1), .builtin(2),
            .builtin(7), .builtin(6),
            .builtin(4), .builtin(5),
        ]))
    }

    @Test("a partially-hidden shortcut set keeps its hidden item, modifiers still forced on")
    func partialEnabledSubsetPreserved() {
        // The user hid escape (6) but kept tab (7) shown.
        let widened = migration.widenedToV3(
            order: [.builtin(7), .builtin(6)],
            enabled: [.builtin(7)],
            forcedLeading: forcedLeading,
            forcedTrailing: forcedTrailing
        )
        // escape stays in the order but hidden; the forced modifiers/zoom are shown.
        #expect(widened.order == [
            .builtin(0), .builtin(1), .builtin(2),
            .builtin(7), .builtin(6),
            .builtin(4), .builtin(5),
        ])
        #expect(Set(widened.enabled) == Set([
            .builtin(7),                            // user's still-shown shortcut
            .builtin(0), .builtin(1), .builtin(2),  // forced modifiers
            .builtin(4), .builtin(5),               // forced zoom
        ]))
        #expect(!widened.enabled.contains(.builtin(6))) // escape stays hidden
    }

    @Test("nil saved enabled treats all saved-order ids as shown, plus forced built-ins")
    func nilEnabledShowsSavedPlusForced() {
        let widened = migration.widenedToV3(
            order: [.builtin(7), .builtin(6)],
            enabled: nil,
            forcedLeading: forcedLeading,
            forcedTrailing: forcedTrailing
        )
        #expect(Set(widened.enabled) == Set([
            .builtin(7), .builtin(6),
            .builtin(0), .builtin(1), .builtin(2),
            .builtin(4), .builtin(5),
        ]))
    }

    @Test("a forced id already present in the saved order keeps its position, no duplicate")
    func forcedIdAlreadyPresentNotDuplicated() {
        // command (2) somehow already sits in the middle of the saved order.
        let widened = migration.widenedToV3(
            order: [.builtin(7), .builtin(2), .builtin(6)],
            enabled: [.builtin(7), .builtin(2), .builtin(6)],
            forcedLeading: forcedLeading,
            forcedTrailing: forcedTrailing
        )
        // Only the missing leading ids (0, 1) prepend; command (2) stays put.
        #expect(widened.order == [
            .builtin(0), .builtin(1),
            .builtin(7), .builtin(2), .builtin(6),
            .builtin(4), .builtin(5),
        ])
        // No duplicate command in the enabled set.
        #expect(widened.enabled.filter { $0 == .builtin(2) }.count == 1)
    }

    @Test("widened layout round-trips through the reducer without dropping forced built-ins")
    func roundTripsThroughReducer() {
        // The reducer's configurable universe now includes the forced built-ins.
        let configurable = [0, 1, 2, 4, 5, 6, 7].map { ToolbarItemID.builtin($0) }
        let reducer = TerminalAccessoryLayoutReducer(configurable: configurable)
        let widened = migration.widenedToV3(
            order: [.builtin(7), .builtin(6)],
            enabled: [.builtin(7)],
            forcedLeading: forcedLeading,
            forcedTrailing: forcedTrailing
        )
        let layout = reducer.load(savedOrder: widened.order, savedEnabled: widened.enabled)
        // Forced modifiers/zoom present and shown; user's hidden escape stays hidden.
        #expect(layout.visibleOrder == [
            .builtin(0), .builtin(1), .builtin(2),
            .builtin(7),
            .builtin(4), .builtin(5),
        ])
        #expect(layout.order.contains(.builtin(6)))
        #expect(!layout.enabled.contains(.builtin(6)))
    }

    @Test("a saved custom action keeps its relative position with modifiers in front, zoom behind")
    func customActionSurvivesWideningInPlace() {
        let custom = UUID()
        // A v2 user with one custom action between two shortcuts, all shown.
        let widened = migration.widenedToV3(
            order: [.builtin(7), .custom(custom), .builtin(6)],
            enabled: [.builtin(7), .custom(custom), .builtin(6)],
            forcedLeading: forcedLeading,
            forcedTrailing: forcedTrailing
        )
        // The custom keeps its saved slot, untouched; modifiers prepend, zoom appends.
        #expect(widened.order == [
            .builtin(0), .builtin(1), .builtin(2),
            .builtin(7), .custom(custom), .builtin(6),
            .builtin(4), .builtin(5),
        ])
        // The custom stays shown alongside the force-enabled modifiers/zoom.
        #expect(widened.enabled.contains(.custom(custom)))
        #expect(Set(widened.enabled) == Set([
            .builtin(0), .builtin(1), .builtin(2),
            .builtin(7), .custom(custom), .builtin(6),
            .builtin(4), .builtin(5),
        ]))
    }
}

@Suite("CustomToolbarAction")
struct CustomToolbarActionTests {
    @Test("text payload normalizes newlines to carriage returns")
    func textOutput() {
        let action = CustomToolbarAction(title: "Claude", payload: .text("claude\n"))
        #expect(action.output == Data("claude\r".utf8))
    }

    @Test("empty text payload produces no output")
    func emptyText() {
        #expect(CustomToolbarAction(title: "x", payload: .text("")).output == nil)
        #expect(CustomToolbarAction(title: "x", payload: .text("\n")).output == Data("\r".utf8))
    }

    @Test("key combo payload encodes through TerminalKeyEncoder")
    func keyComboOutput() {
        let shiftTab = CustomToolbarAction(
            title: "⇧Tab",
            payload: .keyCombo(modifiers: [.shift], key: .tab)
        )
        #expect(shiftTab.output == Data([0x1B, 0x5B, 0x5A]))
        let altLeft = CustomToolbarAction(
            title: "⌥←",
            payload: .keyCombo(modifiers: [.alternate], key: .leftArrow)
        )
        #expect(altLeft.output == Data([0x1B, 0x62]))
    }

    @Test("unencodable key combo produces no output")
    func unencodableCombo() {
        let action = CustomToolbarAction(
            title: "x",
            payload: .keyCombo(modifiers: [.control], key: .upArrow)
        )
        #expect(action.output == nil)
    }

    @Test("Codable round-trips both payload kinds and identity")
    func codable() throws {
        let actions = [
            CustomToolbarAction(title: "Claude", symbolName: "sparkles", payload: .text("claude\n")),
            CustomToolbarAction(title: "⇧Tab", payload: .keyCombo(modifiers: [.shift], key: .tab)),
        ]
        let data = try JSONEncoder().encode(actions)
        let decoded = try JSONDecoder().decode([CustomToolbarAction].self, from: data)
        #expect(decoded == actions)
    }
}
