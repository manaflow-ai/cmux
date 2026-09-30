import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// Per-tab color (`TabItem.tint`) and inline rename, used by the screen tab
/// bar (screens are as customizable as tabs).
@MainActor @Suite struct TabCustomizationTests {
    private func strip(_ items: [TabItem]) -> (TabStripView, TabStripModel, IntentLog) {
        let model = TabStripModel(tabs: items, selectedID: items.first?.id)
        let log = IntentLog()
        model.intentHandler = { log.intents.append($0) }
        let view = TabStripView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        view.layoutSubtreeIfNeeded()
        return (view, model, log)
    }

    @Test func tintDefaultsToNoneAndChangesEquality() {
        let plain = TabItem(id: "a", title: "A")
        #expect(plain.tint == nil)
        var tinted = plain
        tinted.tint = .green
        #expect(tinted != plain)
    }

    @Test func tintedTabWithoutIconShowsAColorDot() {
        var item = TabItem(id: "a", title: "A", icon: .none)
        #expect(TabCell(item: item).iconLayer.contents == nil)
        item.tint = .orange
        #expect(TabCell(item: item).iconLayer.contents != nil)
    }

    @Test func inlineRenameCommitsTheTrimmedName() throws {
        let (view, _, log) = strip([TabItem(id: "a", title: "Logs"), TabItem(id: "b", title: "Build")])
        view.beginInlineRename("b")
        let editor = try #require(view.inlineRenameField)
        #expect(editor.stringValue == "Build")
        editor.stringValue = "  Deploy  "
        view.commitInlineRename()
        #expect(view.inlineRenameField == nil)
        #expect(log.intents.last == .renameCommitted("b", name: "Deploy"))
    }

    @Test func inlineRenameCancelSendsNothing() throws {
        let (view, _, log) = strip([TabItem(id: "a", title: "Logs")])
        view.beginInlineRename("a")
        try #require(view.inlineRenameField).stringValue = "Other"
        view.cancelInlineRename()
        #expect(view.inlineRenameField == nil)
        #expect(!log.intents.contains { if case .renameCommitted = $0 { true } else { false } })
    }

    @Test func inlineRenameIgnoresUnknownTabs() {
        let (view, _, _) = strip([TabItem(id: "a", title: "Logs")])
        view.beginInlineRename("missing")
        #expect(view.inlineRenameField == nil)
    }
}

@MainActor private final class IntentLog {
    var intents: [TabStripIntent] = []
}
