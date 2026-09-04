import Foundation
import Testing

@testable import CmuxSettings

@Suite struct ShortcutBindingsSnapshotTests {
    @Test func decodesBindingsIndependentlyAndRetainsManagedActionIDs() throws {
        let raw: [String: Any] = [
            "globalSearch": "cmd+alt+f",
            "newSurface": ["ctrl+b", "c"],
            "showHideAllWindows": 42,
            "openSettings": NSNull(),
        ]

        let snapshot = try #require(
            ShortcutBindingsSnapshot.decodeFromJSON(raw)
        )

        #expect(snapshot.managedActionIDs == Set(raw.keys))
        #expect(snapshot.bindings["globalSearch"] == StoredShortcut(
            first: ShortcutStroke(key: "f", command: true, option: true)
        ))
        #expect(snapshot.bindings["newSurface"] == StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "c")
        ))
        #expect(snapshot.bindings["showHideAllWindows"] == nil)
        #expect(snapshot.bindings["openSettings"] == .unbound)
    }

    @Test func decodesBareBindingBeforeActionSpecificPolicyRuns() throws {
        let shortcut = try #require(StoredShortcut.decodeFromJSON("j"))

        #expect(shortcut == StoredShortcut(first: ShortcutStroke(key: "j")))
    }

    @Test(arguments: ["", "none", "clear", "unbound", "disabled"])
    func prefixUnboundAliasesDecodeAsDisabled(_ alias: String) throws {
        #expect(StoredShortcut.decodeFromJSON(alias) == .unbound)
    }

    @Test func prefixAcceptsStringAndOneItemArrayForms() throws {
        let expected = StoredShortcut(first: ShortcutStroke(key: "b", control: true))
        #expect(StoredShortcut.decodeFromJSON("ctrl+b") == expected)
        #expect(StoredShortcut.decodeFromJSON(["ctrl+b"]) == expected)
        #expect(StoredShortcut.decodeFromJSON([String]()) == .unbound)
    }

    @Test func prefixAcceptsTheRecorderObjectForm() throws {
        let raw: [String: Any] = [
            "first": [
                "key": "b",
                "command": false,
                "shift": false,
                "option": false,
                "control": true,
                "keyCode": 11,
            ],
            "second": NSNull(),
        ]
        let expected = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true, keyCode: 11)
        )
        #expect(StoredShortcut.decodeFromJSON(raw) == expected)
    }

    @Test func routingEquivalenceIgnoresRecordingKeyCodeMetadata() {
        let recorded = ShortcutStroke(key: "b", control: true, keyCode: 11)
        let handWritten = ShortcutStroke(key: "b", control: true)
        let differentKey = ShortcutStroke(key: "c", control: true)

        #expect(recorded.isRoutingEquivalent(to: handWritten))
        #expect(handWritten.isRoutingEquivalent(to: recorded))
        #expect(!recorded.isRoutingEquivalent(to: differentKey))
    }
}
