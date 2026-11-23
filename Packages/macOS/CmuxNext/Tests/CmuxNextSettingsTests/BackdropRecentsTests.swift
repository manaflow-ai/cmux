@testable import CmuxNextSettings
import Testing

/// `appearance.backgroundRecents` (Leo, 2026-11-22: "it was cumbersome back then to switch back"):
/// the app validates it as cmux-config does and swaps to the newest recent that is not shown.
@Suite struct BackdropRecentsTests {
    private static func root(_ background: String?, _ recents: [String]) -> JSONValue {
        var appearance: [String: JSONValue] = ["backgroundRecents": .array(recents.map(JSONValue.string))]
        if let background { appearance["background"] = .string(background) }
        return .object(["appearance": .object(appearance)])
    }

    @Test func acceptsBackgroundsOnlyEachOnceAtMostEight() {
        #expect(BackdropSelectionSetting.acceptsRecents(.array([])))
        #expect(BackdropSelectionSetting.acceptsRecents(.array(["folder:/Users/me/Art", "daily", "none", "file:/Users/me/a.png"].map(JSONValue.string))))
        #expect(!BackdropSelectionSetting.acceptsRecents(.string("daily")))
        #expect(!BackdropSelectionSetting.acceptsRecents(.array([.string("daily"), .string("daily")])))
        #expect(!BackdropSelectionSetting.acceptsRecents(.array([.string("__not_a_backdrop__")])))
        #expect(!BackdropSelectionSetting.acceptsRecents(.array([.string("folder:relative")])))
        let nine = (1...9).map { JSONValue.string("folder:/Art/\($0)") }
        #expect(!BackdropSelectionSetting.acceptsRecents(.array(nine)))
        #expect(BackdropSelectionSetting.acceptsRecents(.array(Array(nine.prefix(8)))))
    }

    @Test func previousSkipsTheShownBackground() {
        #expect(BackdropSelectionSetting.previous(in: Self.root("folder:/Art", ["folder:/Art", "munch-scream"])) == "munch-scream")
        #expect(BackdropSelectionSetting.previous(in: Self.root("munch-scream", ["folder:/Art"])) == "folder:/Art")
        // Unset is None.
        #expect(BackdropSelectionSetting.previous(in: Self.root(nil, ["none", "daily"])) == "daily")
        #expect(BackdropSelectionSetting.previous(in: Self.root("daily", [])) == nil)
    }

    @Test func recentsDropJunk() {
        #expect(BackdropSelectionSetting.recents(in: Self.root(nil, ["daily", "__junk__", "daily", "folder:/Art"])) == ["daily", "folder:/Art"])
    }

    @Test func aFolderShowsByItsName() {
        let label = BackdropSelectionSetting.recentLabel("folder:/Users/me/Pictures/Paris")
        #expect(label.title == "Paris")
        #expect(label.symbol == "folder")
        #expect(BackdropSelectionSetting.recentLabel("file:/Users/Shared/Harbor.png").title == "Harbor")
        #expect(BackdropSelectionSetting.recentLabel("daily").symbol == "shuffle")
    }
}
