import AppKit
@testable import CmuxNextAccounts
@testable import CmuxNextApps
import CmuxNextDesign
import CmuxNextTestSupport
import SwiftUI
import Testing

/// Theme sweep 3, batch D: SwiftUI panes drew AppKit's controls whatever the room's theme: a search
/// field and the bookmark editor's name were `.roundedBorder` fields (system bezel, text and gray
/// placeholder), the folder choice a stock pop-up, and Accounts' refresh a gray `ProgressView`.
/// Hosted in a purple room, each draws the scope's tokens: the field's ink and hint, the pop-up's
/// theme bezel, the spinner's loading ink (Accounts' refresh).
@MainActor @Suite(.serialized, .closesItsWindows) struct ThemedSwiftUIControlsTests {
    /// `view` hosted in a window whose content roots the purple room.
    private static func host(_ view: some View, _ scope: ThemeScope, size: NSSize = NSSize(width: 520, height: 480)) throws -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = hosting
        scope.root(hosting)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// A search field as a SwiftUI pane draws it (the native History page's was the first; it is a
    /// React page now).
    private static var searchField: some View {
        ThemedField(text: .constant(""), placeholder: "Search", font: Typography.subtitle, focusOnAppear: true)
    }

    @Test func aSearchFieldIsAThemedField() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let (window, root) = try Self.host(Self.searchField, scope)
        defer { window.contentView = nil; window.close() }
        let fields = HomeSheetThemeTests.editableFields(in: root)
        #expect(fields.count == 1, "the search field")
        for field in fields { Self.expectThemedField(field, scope, placeholder: true) }
    }

    @Test func accountsRefreshSpinnerDrawsTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let model = AccountsModel(services: MockAccountsServices())
        model.refresh()
        #expect(model.isRefreshing)
        let (window, root) = try Self.host(AccountsSectionView(model: model, palette: AccountsPalette(tokens: scope.tokens)), scope)
        defer { window.contentView = nil; window.close() }
        #expect(Self.all(NSProgressIndicator.self, in: root).isEmpty,
                "no AppKit spinner: it draws the appearance's gray")
        let spinner = try #require(Self.all(StatusIndicatorView.self, in: root).first { !$0.isHidden },
                                   "a visible themed spinner")
        #expect(spinner.state == .busy)
        spinner.updateLayer()
        let loading = try #require(spinner.indicator.colors.flatMap { NSColor(cgColor: $0.loading) })
        #expect(ThemedOverlayColorsTests.same(loading, scope.perform { Palette.textSecondary }), "\(loading)")
    }

    /// A search that took the keyboard when it first appeared takes it again when its view comes
    /// back to the window (its tab shown again), as SwiftUI's `.onAppear` focus did.
    @Test func aSearchTakesTheKeyboardAgainWhenItComesBack() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let (window, root) = try Self.host(Self.searchField, scope)
        defer { window.contentView = nil; window.close() }
        let field = try #require(HomeSheetThemeTests.editableFields(in: root).first)
        #expect(Self.isEditing(field, in: window), "the search takes the keyboard when it appears")

        window.contentView = nil
        window.makeFirstResponder(nil)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        #expect(Self.isEditing(field, in: window), "and again when it comes back")
    }

    /// A field's box follows a height change (a live density change of `Metrics.controlHeight`).
    @Test func aFieldsBoxFollowsItsHeight() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let text = Binding.constant("")
        let hosting = NSHostingView(rootView: ThemedField(text: text, height: 24).frame(width: 200, height: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = hosting
        scope.root(hosting)
        hosting.layoutSubtreeIfNeeded()
        let box = try #require(Self.all(ThemedFieldBox.self, in: hosting).first)
        #expect(box.frame.height == 24)

        hosting.rootView = ThemedField(text: text, height: 32).frame(width: 200, height: 60)
        hosting.layoutSubtreeIfNeeded()
        #expect(box.frame.height == 32, "the box resizes: \(box.frame.height)")
    }

    private static func isEditing(_ field: NSTextField, in window: NSWindow) -> Bool {
        window.firstResponder === field || (window.firstResponder as? NSTextView)?.delegate === field
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews { found += all(type, in: subview) }
        return found
    }

    private static func expectThemedField(_ field: NSTextField, _ scope: ThemeScope, placeholder: Bool) {
        let name = field.accessibilityIdentifier().isEmpty ? "\(type(of: field))" : field.accessibilityIdentifier()
        #expect(!field.isBezeled && !field.drawsBackground, "\(name): AppKit's bezel and fill are gone")
        let ink = scope.perform { Palette.textPrimary }
        #expect(field.textColor.map { ThemedOverlayColorsTests.same($0, ink) } == true, "\(name): text in the theme ink")
        guard placeholder else { return }
        let hint = field.placeholderAttributedString.flatMap { text in
            text.length > 0 ? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        }
        #expect(hint.map { ThemedOverlayColorsTests.same($0, scope.perform { Palette.textTertiary }) } == true,
                "\(name): placeholder in the theme hint ink")
    }
}
