import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
@testable import CmuxNextFeed
@testable import CmuxNextTasks
import CmuxNextTestSupport
import Foundation
import SwiftUI
import Testing

/// Theme sweep 3, batch G: the SwiftUI `.plain` text fields that sit in their own chrome (a row, a
/// capsule search, a filled reply box) were SwiftUI's stock fields, so their placeholder drew
/// macOS's gray, and their text and caret the appearance's, whatever the room's theme: the new-task
/// field, the app store search, the feed inbox filter, the feed's reply field and an app scene's
/// text field. Hosted in a purple room, each draws the scope's text and hint inks.
@MainActor @Suite(.serialized, .closesItsWindows) struct ThemedPlainFieldsTests {
    /// `view` hosted in a window whose content roots the purple room.
    private static func host(_ view: some View, _ scope: ThemeScope, size: NSSize = NSSize(width: 520, height: 320)) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = hosting
        scope.root(hosting)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// The one editable field in `root`: unbezeled with no AppKit fill, text in the theme's ink and
    /// the placeholder `placeholder` in its hint ink.
    private static func expectThemedField(in root: NSView, _ scope: ThemeScope, placeholder: String, _ name: String) throws {
        let fields = HomeSheetThemeTests.editableFields(in: root)
        #expect(fields.count == 1, "\(name): one field, found \(fields.count)")
        let field = try #require(fields.first, "\(name): the field")
        #expect(!field.isBezeled && !field.drawsBackground, "\(name): AppKit's bezel and fill are gone")
        let ink = scope.perform { Palette.textPrimary }
        #expect(field.textColor.map { ThemedOverlayColorsTests.same($0, ink) } == true,
                "\(name): text in the theme ink, not \(String(describing: field.textColor))")
        let hint = try #require(field.placeholderAttributedString, "\(name): the placeholder carries the theme's hint ink, not macOS's gray")
        #expect(hint.string == placeholder, "\(name): \(hint.string)")
        let color = hint.length > 0 ? hint.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        #expect(color.map { ThemedOverlayColorsTests.same($0, scope.perform { Palette.textTertiary }) } == true,
                "\(name): placeholder in the theme hint ink, not \(String(describing: color))")
    }

    /// Runs the main run loop until `condition` holds (SwiftUI applies state changes on its next pass).
    private static func settle(_ root: NSView, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            root.layoutSubtreeIfNeeded()
        }
    }

    private static func isEditing(_ field: NSTextField, in window: NSWindow) -> Bool {
        window.firstResponder === field || (window.firstResponder as? NSTextView)?.delegate === field
    }

    @Test func theNewTaskFieldDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let (window, root) = Self.host(NewTaskField(model: TasksModel(source: MockTasksSource())), scope)
        defer { window.contentView = nil; window.close() }
        try Self.expectThemedField(in: root, scope, placeholder: TasksStrings.newTaskPlaceholder, "new task")
    }

    @Test func theFeedInboxFilterDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let header = FeedInboxHeader(filter: .constant(FeedInboxFilter()), hasUnread: true, canRefresh: true, canAddConnection: false,
                                     markRead: {}, refresh: {}, addConnection: {})
        let (window, root) = Self.host(header, scope)
        defer { window.contentView = nil; window.close() }
        try Self.expectThemedField(in: root, scope, placeholder: FeedStrings.filterInbox, "feed filter")
    }

    @Test func theFeedReplyFieldDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let (window, root) = Self.host(FeedTextField(placeholder: FeedStrings.reply, text: .constant("")), scope)
        defer { window.contentView = nil; window.close() }
        try Self.expectThemedField(in: root, scope, placeholder: FeedStrings.reply, "feed reply")
    }

    @Test func anAppSceneTextFieldDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let model = AppSceneModel()
        model.apply([.create(id: "name", type: "TextField", props: ["placeholder": .string("Name")]), .root(id: "name")])
        let (window, root) = Self.host(AppSceneNodeView(model: model, id: "name"), scope, size: NSSize(width: 240, height: 60))
        defer { window.contentView = nil; window.close() }
        try Self.expectThemedField(in: root, scope, placeholder: "Name", "app scene field")
    }

    /// VoiceOver still names a field once it holds text: the stock field's title was its label, and
    /// the themed placeholder alone disappears when text is typed.
    @Test func aFieldWithTextKeepsItsPlaceholderAsItsLabel() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let header = FeedInboxHeader(filter: .constant(FeedInboxFilter(query: "bug")), hasUnread: true, canRefresh: true,
                                     canAddConnection: false, markRead: {}, refresh: {}, addConnection: {})
        let (window, root) = Self.host(header, scope)
        defer { window.contentView = nil; window.close() }
        let field = try #require(HomeSheetThemeTests.editableFields(in: root).first)
        #expect(field.stringValue == "bug")
        #expect(field.accessibilityLabel() == FeedStrings.filterInbox, "label: \(String(describing: field.accessibilityLabel()))")

        let reply = FeedTextField(placeholder: FeedStrings.reply, text: .constant("Looks good"))
        let (replyWindow, replyRoot) = Self.host(reply, scope)
        defer { replyWindow.contentView = nil; replyWindow.close() }
        let replyField = try #require(HomeSheetThemeTests.editableFields(in: replyRoot).first)
        #expect(replyField.accessibilityLabel() == FeedStrings.reply, "label: \(String(describing: replyField.accessibilityLabel()))")
    }

    /// New Task still puts the keyboard in the field, and Escape still clears it and lets go.
    @Test func newTaskFocusesTheFieldAndEscapeClearsIt() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let model = TasksModel(source: MockTasksSource())
        model.focusNewTask()
        let (window, root) = Self.host(NewTaskField(model: model), scope)
        defer { window.contentView = nil; window.close() }
        let field = try #require(HomeSheetThemeTests.editableFields(in: root).first)
        Self.settle(root) { Self.isEditing(field, in: window) }
        #expect(Self.isEditing(field, in: window), "New Task gives the field the keyboard")

        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Buy milk", replacementRange: NSRange(location: 0, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        Self.settle(root) { field.stringValue.isEmpty && !Self.isEditing(field, in: window) }
        #expect(field.stringValue.isEmpty, "Escape clears the title: \(field.stringValue)")
        #expect(!Self.isEditing(field, in: window), "and lets go of the keyboard")
    }
}
