import AppKit
@testable import CmuxNextAccounts
@testable import CmuxNextApps
@testable import CmuxNextBookmarks
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxTheme
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

    @Test func theBookmarkEditorsNameAndFolderDrawTheTheme() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let model = BookmarkEditModel(isNew: true, title: "Docs", folder: "bar", folders: [
            BookmarkFolderChoice(id: "bar", title: "Bookmarks Bar", depth: 0),
            BookmarkFolderChoice(id: "other", title: "Other Bookmarks", depth: 0),
        ])
        let (window, root) = try Self.host(BookmarkEditView(model: model), scope)
        defer { window.contentView = nil; window.close() }
        let fields = HomeSheetThemeTests.editableFields(in: root)
        #expect(fields.count == 1, "the name field")
        for field in fields { Self.expectThemedField(field, scope, placeholder: false) }

        let popups = Self.all(NSPopUpButton.self, in: root)
        #expect(popups.count == 1, "the folder choice")
        for popup in popups {
            #expect(popup is ThemedPopUpButton, "a themed pop-up, not SwiftUI's stock one")
            let bezel = try #require(popup.bezelColor, "the pop-up has a theme bezel")
            #expect(ThemedOverlayColorsTests.same(bezel, scope.perform { Palette.selectionFill }))
            #expect(popup.titleOfSelectedItem == "Bookmarks Bar", "the binding's choice is selected")
        }
    }

    /// a1273 (user 2026-11-20, "more/remove are not very visible"): the bubble's More… and Remove were stock SwiftUI
    /// buttons, which draw AppKit's bezel and label (no fill on the glass, a dimmed gray title) instead of the theme, and
    /// read as disabled next to Done. Each is a cmux dialog button now: a theme fill that reads as a button, its title at
    /// least 4.5:1 over the fill on the menu glass whatever page shows through it (white or black), light and dark.
    @Test(arguments: [false, true])
    func theBookmarkBubblesButtonsReadAsButtons(dark: Bool) throws {
        let input = dark ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6))
            : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(dark ? "Bubble Dark" : "Bubble Light"), input: input, animated: false)
        let model = BookmarkEditModel(isNew: false, title: "Docs", folder: "bar", folders: [
            BookmarkFolderChoice(id: "bar", title: "Bookmarks Bar", depth: 0),
        ])
        let hosting = NSHostingView(rootView: BookmarkEditView(model: model))
        let card = Glass.makeMenuPanel(content: hosting)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = card
        scope.root(card)
        card.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        let tokens = scope.tokens
        // The menu glass (its tint at the menu level, then the theme veil) over the brightest and darkest page.
        let pages = [ThemeRGB(red: 1, green: 1, blue: 1), ThemeRGB(red: 0, green: 0, blue: 0)]
            .map { GlassMenuMaterial.glass(tokens, veil: GlassMenuMaterial.veil(for: tokens), over: $0) }

        let buttons = Self.all(CmuxDialogButtonView.self, in: hosting)
        #expect(Set(buttons.map(\.button.title)) == [BookmarkStrings.more, BookmarkStrings.remove, BookmarkStrings.done],
                "More…, Remove and Done are cmux dialog buttons, not stock ones: \(buttons.map(\.button.title))")
        for button in buttons {
            let name = button.button.title
            #expect(button.alphaValue == 1, "\(name) is enabled, not dimmed")
            let fill = try #require(button.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }.flatMap(Self.rgb))
            #expect(fill.alpha > 0.05, "\(name) has a fill that reads as a button: \(fill)")
            let title = button.attributedTitle
            let ink = try #require((title.length > 0 ? title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil).flatMap(Self.rgb))
            for page in pages {
                let under = fill.composited(over: page)
                #expect(ink.contrast(with: under) >= 4.5, "\(name): \(ink.contrast(with: under)):1 on \(under)")
            }
            // A click at the button's middle goes to the SwiftUI button that runs the action, never to the face that
            // draws it (a face that took the click would swallow it: the bubble's buttons would do nothing).
            let root = try #require(window.contentView)
            let middle = root.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            let hit = root.hitTest(root.superview.map { root.convert(middle, to: $0) } ?? middle)
            #expect(hit != nil && hit !== button && !(hit is CmuxDialogButtonView), "\(name)'s click reaches SwiftUI: \(String(describing: hit))")
        }
    }

    private static func rgb(_ color: NSColor) -> ThemeRGB? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
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

    /// Choosing a folder from the pop-up's menu, as a click does, updates the binding.
    @Test func choosingAFolderUpdatesTheBinding() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let model = BookmarkEditModel(isNew: true, title: "Docs", folder: "bar", folders: [
            BookmarkFolderChoice(id: "bar", title: "Bookmarks Bar", depth: 0),
            BookmarkFolderChoice(id: "other", title: "Other Bookmarks", depth: 0),
        ])
        let (window, root) = try Self.host(BookmarkEditView(model: model), scope)
        defer { window.contentView = nil; window.close() }
        let popup = try #require(Self.all(NSPopUpButton.self, in: root).first)
        let menu = try #require(popup.menu)
        menu.performActionForItem(at: 1)
        #expect(model.folder == "other", "the chosen folder reaches the model")
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
        #expect(hint.map { ThemedOverlayColorsTests.same($0, scope.perform { Palette.textSecondary }) } == true,
                "\(name): placeholder in the theme hint ink")
    }
}
