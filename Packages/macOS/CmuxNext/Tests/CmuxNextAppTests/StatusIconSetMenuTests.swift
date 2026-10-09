import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// cx-kxa2: Debug menu > Status Icons lists every candidate set with a check
/// on the chosen one and writes the same Debug Settings tunable.
@MainActor @Suite(.serialized) struct StatusIconSetMenuTests {
    @Test func theMenuListsEverySetAndWritesTheTunable() throws {
        let store = TunableStore()
        store.register([StatusIconSet.tunable.descriptor])
        store.activate(file: nil)
        let menu = StatusIconSetMenu()
        menu.store = store
        let item = menu.makeItem()
        #expect(item.title == Strings.menuStatusIcons)
        let choices = try #require(item.submenu?.items)
        #expect(choices.map { $0.representedObject as? String } == StatusIconSet.allCases.map(\.rawValue))
        #expect(choices.map(\.title) == StatusIconSet.allCases.map(\.tunableTitle))
        #expect(choices.first { $0.state == .on }?.representedObject as? String == StatusIconSet.symbols.rawValue)

        menu.select(.badges)
        #expect(StatusIconSet.tunable.value(in: store) == .badges)
        menu.menuNeedsUpdate(try #require(item.submenu))
        #expect(choices.first { $0.state == .on }?.representedObject as? String == "badges")

        menu.select(.symbols)
        #expect(store.override(StatusIconSet.tunable.key) == nil, "choosing the default removes the override")
        #expect(StatusIconSet.tunable.value(in: store) == .symbols)
        menu.select(.current)
        #expect(StatusIconSet.tunable.value(in: store) == .current, "the original dots stay one choice away")
    }
}
