import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextScreenshots
import Testing
import WebKit

/// An agent's `cmux window screenshot` of Home came back flat grey and was read as a blank pane
/// (air-blue, DEV build of #44303): the grey is the privacy mask over Home's views, but the
/// result only said `masked: N`. A masked capture now names what each grey area is
/// (`masked_areas`: `home`, `chat`, `browser`, ...), in its JSON and in the CLI's line.
@MainActor @Suite(.closesItsWindows, .serialized) struct MaskedScreenshotAreaNameTests {
    /// A window with `views` side by side, never put on screen: `ScreenshotMask.read` walks the view tree only.
    func window(_ views: [NSView]) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        for (index, view) in views.enumerated() {
            view.frame = NSRect(x: CGFloat(index) * 100 + 4, y: 4, width: 90, height: 90)
            content.addSubview(view)
        }
        window.contentView = content
        return window
    }

    /// Every Home view the mask covers is named `home`, never left as an unnamed area.
    @Test func homeViewsAreNamedHome() {
        let views: [NSView] = [HomeSidebarView(frame: .zero), HomeDockSwitchView(mode: .messages)]
        let window = window(views)
        defer { window.close() }
        let mask = ScreenshotMask.read(window, rules: .app)
        #expect(mask.names.count == mask.regions.count, "one name per masked area")
        for view in views {
            let rect = view.convert(view.bounds, to: nil)
            let index = mask.regions.firstIndex(of: rect)
            #expect(index != nil, "\(type(of: view)) is masked")
            if let index { #expect(mask.names[index] == "home", "\(type(of: view)) is named home") }
        }
    }

    /// The docked Home is a native page tab the mask covers whole, so its area is named by the page:
    /// `home`, never `page:home-dock` (the capture that read grey was of this tab).
    @Test func theDockedHomePageIsNamedHome() {
        let home = InternalPageView(key: "k", page: .homeDock, content: NSView())
        let other = InternalPageView(key: "k2", page: InternalPageID(rawValue: "cmux.not-checked"), content: NSView())
        #expect(ScreenshotMask.areaName(home) == "home")
        #expect(ScreenshotMask.areaName(other) == "page:cmux.not-checked")
        let window = window([home])
        defer { window.close() }
        let mask = ScreenshotMask.read(window, rules: .app)
        let index = mask.regions.firstIndex(of: home.convert(home.bounds, to: nil))
        #expect(index != nil, "the docked Home is masked")
        if let index { #expect(mask.names[index] == "home") }
    }

    /// A browser pane is `browser`; an unknown covered view never comes back without a name.
    @Test func aBrowserPaneIsNamedBrowser() {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let chrome = BrowserChromeView(tab: page)
        let window = window([chrome])
        defer { window.close() }
        let mask = ScreenshotMask.read(window, rules: .app)
        let index = mask.regions.firstIndex(of: chrome.convert(chrome.bounds, to: nil))
        #expect(index != nil)
        if let index { #expect(mask.names[index] == "browser") }
        #expect(!mask.names.contains(""))
    }

    /// The run's result: `masked_areas` lists each name once, sorted, beside `masked`; a crop lists
    /// only the areas inside it; a person's raw capture has neither field.
    @Test func theResultListsTheMaskedAreas() throws {
        let image = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let areas = [ScreenshotMask.Area(name: "home", rect: NSRect(x: 0, y: 0, width: 50, height: 50)),
                     ScreenshotMask.Area(name: "chat", rect: NSRect(x: 100, y: 0, width: 50, height: 50)),
                     ScreenshotMask.Area(name: "home", rect: NSRect(x: 0, y: 60, width: 50, height: 50))]
        #expect(ScreenshotMask.Area.names(areas, in: nil) == ["chat", "home"])
        #expect(ScreenshotMask.Area.names(areas, in: NSRect(x: 0, y: 0, width: 60, height: 120)) == ["home"])

        let masked = ScreenshotHandlers.Capture(image: image, scale: 2, method: "window", masked: 3,
                                                maskedAreas: ScreenshotMask.Area.names(areas, in: nil))
        #expect(masked.fields["masked"] == .int(3))
        #expect(masked.fields["masked_areas"] == .array([.string("chat"), .string("home")]))
        let raw = ScreenshotHandlers.Capture(image: image, scale: 2, method: "window")
        #expect(raw.fields["masked"] == nil)
        #expect(raw.fields["masked_areas"] == nil)
    }
}
