import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// The omnibar view in an offscreen window: focus selects the full URL,
/// Enter commits and reports the event, Escape reverts then cancels, and a
/// commit without an App router returns focus to the page. With
/// `OMNIBAR_SNAPSHOT_DIR` set it also writes idle, focused, and suggestion
/// PNGs (light and dark) for visual review; the window is never shown.
@MainActor
@Suite(.serialized) struct OmnibarViewTests {
    final class Harness {
        let window: NSWindow
        let chrome: BrowserChromeView
        let tab: MockBrowserTab
        var events: [OmnibarEvent] = []

        init(url: String = "https://github.com/manaflow-ai/cmux/pulls", history: [(String, String)] = []) {
            tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
            let store = InMemoryBrowserHistory()
            for (url, title) in history {
                for _ in 0..<5 { store.recordVisit(url: URL(string: url)!, title: title, at: Date()) }
            }
            chrome = BrowserChromeView(tab: tab, suggestionEngine: OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: store)]))
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            tab.load(URL(string: url)!)
        }

        var bar: AddressBarView { chrome.addressBar }
        var editor: NSText? { bar.subviews.compactMap { $0 as? AddressField }.first?.currentEditor() }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            chrome.layoutSubtreeIfNeeded()
        }
    }

    @Test func focusSelectsTheFullURLAndEnterCommits() async {
        let h = Harness()
        await h.settle()
        h.chrome.onOmnibarEvent = { h.events.append($0) }
        h.bar.focus()
        #expect(h.bar.isEditing)
        #expect(h.editor?.string == "https://github.com/manaflow-ai/cmux/pulls")
        #expect(h.editor?.selectedRange == NSRange(location: 0, length: 41))
        h.bar.debugType("example.org")
        await h.settle()
        let editor = h.editor as? NSTextView
        _ = h.bar.control(NSTextField(), textView: editor ?? NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(h.events.first == .didBeginEditing)
        #expect(h.events.last == .didEndEditing(.commit(URL(string: "https://example.org")!)))
        #expect(!h.bar.isEditing)
        await h.settle()
        #expect(h.tab.state.url?.host() == "example.org")
    }

    @Test func escapeRevertsThenCancelsAndFocusReturnsToThePage() async {
        let h = Harness()
        await h.settle()
        h.bar.debugType("typo")
        await h.settle()
        let editor = (h.editor as? NSTextView) ?? NSTextView()
        // Chrome: the first Escape closes the card, the second reverts to
        // the display text, the third returns focus to the page.
        _ = h.bar.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(h.bar.isEditing)
        #expect(h.editor?.string == "typo")
        _ = h.bar.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(h.bar.isEditing)
        #expect(h.editor?.string == "github.com/manaflow-ai/cmux/pulls")
        #expect(h.editor?.selectedRange == NSRange(location: 0, length: 33))
        _ = h.bar.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!h.bar.isEditing)
        // No App router: the chrome hands focus back to the page.
        #expect(h.tab.commands.last == .focus(true))
    }

    @Test func snapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIBAR_SNAPSHOT_DIR"] else { return }
        let history = [
            ("https://github.com/manaflow-ai/cmux", "manaflow-ai/cmux: The terminal for coding agents"),
            ("https://github.com/imputnet/helium", "imputnet/helium: Private, fast, and honest web browser"),
            ("https://gist.github.com/", "Discover gists"),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for density in [Density.compact, .comfortable] {
                DesignSettings.shared.density = density
                let suffix = "\(name)-\(density)"
                let idle = Harness(history: history)
                idle.window.appearance = NSAppearance(named: appearance)
                await idle.settle()
                try write(idle, panel: nil, to: "\(directory)/idle-\(suffix).png")

                let focused = Harness(history: history)
                focused.window.appearance = NSAppearance(named: appearance)
                await focused.settle()
                focused.bar.focus()
                await focused.settle()
                try write(focused, panel: nil, to: "\(directory)/focused-\(suffix).png")

                let typing = Harness(history: history)
                typing.window.appearance = NSAppearance(named: appearance)
                await typing.settle()
                typing.bar.debugType("git")
                await typing.settle()
                let panel = NSApp.windows.first { $0 is SuggestionWindow && $0.isVisible }
                try write(typing, panel: panel, to: "\(directory)/suggestions-\(suffix).png")
                panel?.orderOut(nil)
            }
        }
        DesignSettings.shared.density = .compact
    }

    /// The top of the chrome, plus the suggestion panel composited where it
    /// sits on screen (under the bar).
    private func write(_ h: Harness, panel: NSWindow?, to path: String) throws {
        let windowHeight = h.chrome.bounds.height
        let size = NSSize(width: h.chrome.bounds.width, height: panel == nil ? 60 : 240)
        let offset = size.height - windowHeight
        let image = NSImage(size: size)
        image.lockFocus()
        let dark = h.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: dark ? 0.07 : 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let chromeRep = try #require(h.chrome.bitmapImageRepForCachingDisplay(in: h.chrome.bounds))
        h.chrome.cacheDisplay(in: h.chrome.bounds, to: chromeRep)
        chromeRep.draw(in: NSRect(x: 0, y: offset, width: size.width, height: windowHeight))
        if let panel, let content = panel.contentView {
            let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let x = panel.frame.minX - h.window.frame.minX
            let y = panel.frame.minY - h.window.frame.minY + offset
            rep.draw(in: NSRect(x: x, y: y, width: content.bounds.width, height: content.bounds.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(filePath: path))
    }
}
