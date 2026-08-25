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
}
