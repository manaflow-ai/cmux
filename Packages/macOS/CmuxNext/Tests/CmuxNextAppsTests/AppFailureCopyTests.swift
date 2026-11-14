import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import Testing

/// A failed app mount says what happened in plain words (``AppFailureCopy``), and its row keeps the
/// app host's raw reason for Copy Error and Details only.
@MainActor @Suite(.serialized) struct AppFailureCopyTests {
    @Test(arguments: [
        ("init: main: Error: expecting ';' at eval_script:2:12", "This section's script has an error", "Line 2, column 12: expecting ';'"),
        ("main: SyntaxError: unexpected token in expression: ')' at eval_script:14:3", "This section's script has an error",
         "Line 14, column 3: unexpected token in expression: ')'"),
        ("init: ReferenceError: pulls is not defined\n    at render (eval_script:7:5)", "This section's script has an error",
         "Line 7, column 5: pulls is not defined"),
        ("init: TypeError: cannot read property 'title' of undefined", "This section's script has an error",
         "cannot read property 'title' of undefined"),
        // An empty message: the name's spaces and the place's meet; no reversed range.
        ("init: main: Error: at eval_script:1:1", "This section's script has an error", "Line 1, column 1"),
        // A host that names the script file says which file.
        ("init: main: Error: expecting ';' at main.js:2:12", "This section's script has an error",
         "main.js · Line 2, column 12: expecting ';'"),
        ("init: TypeError: not a function\n    at renderRecent (main.js:45:9)", "This section's script has an error",
         "main.js · Line 45, column 9: not a function"),
        ("init: main: Error: at lib/util.mjs:3:1", "This section's script has an error", "lib/util.mjs · Line 3, column 1"),
    ])
    func aScriptErrorNamesWhereAndWhy(reason: String, title: String, location: String) {
        let copy = AppFailureCopy(reason: reason)
        #expect(copy.title == title)
        #expect(copy.location == location)
        #expect(copy.detail == reason, "the raw reason is kept whole for Copy Error")
    }

    @Test func aBudgetFailureSaysTheSectionIsTooLarge() {
        let copy = AppFailureCopy(reason: "app.limit: more than 5000 scene nodes")
        #expect(copy.title == "This section is too large to show")
        #expect(copy.location == nil)
    }

    @Test(arguments: ["scene op reused node id r1", "no such app", "removed", "the app is disabled"])
    func anyOtherFailureSaysItCouldNotLoad(reason: String) {
        let copy = AppFailureCopy(reason: reason)
        #expect(copy.title == "This section couldn't load")
        #expect(copy.location == nil)
        #expect(copy.detail == reason)
    }

    /// What Copy Error handed over, in place of the pasteboard (a fleet session may have none).
    @MainActor private final class CopyRecorder { var texts: [String] = [] }

    private static func all(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all(in: $0) } }

    @Test func copyErrorHandsOverTheRawReasonAndDetailsShowsIt() throws {
        let raw = "init: main: Error: expecting ';' at eval_script:2:12"
        let copied = CopyRecorder()
        let view = AppSceneNativeView(model: AppSceneModel(status: .failed(raw)), copyText: { copied.texts.append($0) })
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        view.layoutSubtreeIfNeeded()
        let closed = view.preferredHeight(width: 260)
        let buttons = Self.all(in: view).compactMap { $0 as? NSButton }
        let copy = try #require(buttons.first { $0.title == "Copy Error" })
        copy.performClick(nil)
        #expect(copied.texts == [raw])
        #expect(copy.title == "Copied")

        let details = try #require(buttons.first { $0.title == "Details" })
        details.performClick(nil)
        view.layoutSubtreeIfNeeded()
        let shown = Self.all(in: view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? ChromeLabel)?.stringValue }
        #expect(shown.contains(raw))
        #expect(details.title == "Hide Details")
        #expect(view.preferredHeight(width: 260) > closed, "the open Details adds the raw reason's lines")
    }

    /// What Reload asked for, in place of the app host.
    @MainActor private final class ReloadRecorder: AppSceneInteraction {
        var reloads = 0
        func dispatch(node: String, event: String, payload: AppJSON) {}
        func reload() { reloads += 1 }
    }

    @Test func reloadRunsTheScriptAgain() throws {
        let model = AppSceneModel(status: .failed("init: main: Error: expecting ';' at main.js:2:12"))
        let recorder = ReloadRecorder()
        model.interaction = recorder
        let view = AppSceneNativeView(model: model, copyText: { _ in })
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        view.layoutSubtreeIfNeeded()
        let buttons = Self.all(in: view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? NSButton }
        let titles = buttons.map(\.title)
        #expect(titles == ["Reload", "Copy Error", "Details"])
        try #require(buttons.first { $0.title == "Reload" }).performClick(nil)
        #expect(recorder.reloads == 1)
    }

    @Test func aDisconnectedSectionKeepsItsOneLineAndNoButtons() {
        let view = AppSceneNativeView(model: AppSceneModel(status: .disconnected("This machine isn't connected")))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        view.layoutSubtreeIfNeeded()
        let shown = Self.all(in: view).filter { !$0.isHiddenOrHasHiddenAncestor }
        let texts = shown.compactMap { ($0 as? ChromeLabel)?.stringValue }
        let buttons = shown.compactMap { $0 as? NSButton }
        #expect(texts.contains("This machine isn't connected"))
        #expect(buttons.isEmpty)
    }
}
