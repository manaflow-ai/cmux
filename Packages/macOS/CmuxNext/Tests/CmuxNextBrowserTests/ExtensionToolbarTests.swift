import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// The browser toolbar collapses in Chrome's order as its pane narrows:
/// pinned extension buttons move into the Extensions menu first, then the
/// omnibar shrinks to its minimum, then Forward hides. Back, Reload, the
/// omnibar and the Extensions button always stay, inside the toolbar and
/// without overlap, at every pane width, also in a padded pane.
@Suite struct BrowserToolbarLayoutTests {
    let metrics = BrowserToolbarLayout.Metrics(
        button: 28, navigationSpacing: 0, extensionSpacing: 2, inset: 6, margin: 6, preferredAddress: 240, minimumAddress: 120
    )

    func layout(_ width: CGFloat, pinned: Int = 4, extensions: Bool = true) -> BrowserToolbarLayout {
        BrowserToolbarLayout.resolve(width: width, pinned: pinned, showsExtensions: extensions, metrics: metrics)
    }

    func address(_ width: CGFloat, pinned: Int = 4) -> CGFloat {
        BrowserToolbarLayout.addressWidth(width: width, layout: layout(width, pinned: pinned), showsExtensions: true, metrics: metrics)
    }

    @Test func wideShowsEverything() {
        #expect(layout(1400) == BrowserToolbarLayout(visiblePinned: 4, showsForward: true))
        #expect(address(1400) > 240)
    }

    @Test func extensionsCollapseBeforeTheOmnibarGoesBelowItsPreferredWidth() {
        var previous = 4
        for width in stride(from: CGFloat(1400), through: 200, by: -1) {
            let resolved = layout(width)
            #expect(resolved.visiblePinned <= previous)
            previous = resolved.visiblePinned
            if resolved.visiblePinned > 0 { #expect(address(width) >= 240) }
        }
        #expect(previous == 0)
    }

    @Test func forwardHidesOnlyAfterTheOmnibarReachedItsMinimum() {
        for width in stride(from: CGFloat(800), through: 150, by: -1) {
            let resolved = layout(width)
            if resolved.showsForward { #expect(address(width) >= 120) }
            if !resolved.showsForward {
                #expect(resolved.visiblePinned == 0)
                #expect(address(width - 0) < 120 + 28)
            }
        }
        #expect(layout(200).showsForward == false)
        #expect(layout(320).showsForward == true)
    }

    @Test func noExtensionsMeansNoExtensionsButtonWidth() {
        let resolved = layout(250, pinned: 3, extensions: false)
        #expect(resolved == BrowserToolbarLayout(visiblePinned: 0, showsForward: true))
    }
}

@MainActor
@Suite(.serialized) struct ExtensionToolbarViewTests {
    final class Harness {
        let window: NSWindow
        let container = NSView()
        let chrome: BrowserChromeView
        let tab: MockBrowserTab

        /// A chrome `width` wide inside a pane with `padding` on each side.
        init(width: CGFloat, padding: CGFloat = 0, pinned: Int = 4) {
            tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
            let names = ["uBlock Origin", "Bitwarden", "Dark Reader", "Grammarly", "OneTab", "Wappalyzer"]
            tab.installMockExtensions(names.enumerated().map { index, name in
                BrowserExtensionInfo(id: "ext\(index)", name: name, hasAction: true, isPinned: index < pinned)
            })
            chrome = BrowserChromeView(tab: tab)
            chrome.translatesAutoresizingMaskIntoConstraints = false
            let paneWidth = width + 2 * padding
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: paneWidth, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
            container.addSubview(chrome)
            NSLayoutConstraint.activate([
                chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                chrome.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
                chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            ])
            tab.load(URL(string: "https://github.com/manaflow-ai/cmux/pull/15808")!)
        }

        func settle() async {
            for _ in 0..<20 { await Task.yield() }
            container.layoutSubtreeIfNeeded()
            container.layoutSubtreeIfNeeded()
        }
    }

    nonisolated static let widths: [CGFloat] = [200, 320, 480, 800, 1400]

    @Test(arguments: widths, [CGFloat(0), 12])
    func toolbarFitsThePane(width: CGFloat, padding: CGFloat) async {
        let h = Harness(width: width, padding: padding)
        h.chrome.showFindBar()
        await h.settle()
        let report = h.chrome.toolbarReport
        // Nothing in the chrome (omnibar, find bar, prompt bar) widens the pane.
        #expect(report.width == width)
        #expect(report.fits, "controls overlap or leave the toolbar at \(width) pt: \(report.frames)")
        for control in ["back", "reload", "omnibar", "extensions"] {
            #expect(report.frames[control] != nil, "\(control) missing at \(width) pt")
        }
        #expect(report.visibleActions.count + report.overflowActions.count == 4)
        #expect((report.frames["omnibar"]?.width ?? 0) > 40)
    }

    @Test func collapseOrderAtTheVerifiedWidths() async {
        var results: [CGFloat: BrowserToolbarReport] = [:]
        for width in Self.widths {
            let h = Harness(width: width)
            await h.settle()
            results[width] = h.chrome.toolbarReport
        }
        #expect(results[1400]?.visibleActions == ["ext0", "ext1", "ext2", "ext3"])
        #expect(results[200]?.visibleActions == [])
        #expect(results[200]?.showsForward == false, "\(String(describing: results[200])) \(BrowserChromeView.toolbarMetrics)")
        #expect(results[320]?.showsForward == true)
        #expect(results[320]?.visibleActions == [])
        // Buttons leave from the end, in Chromium's pinned order.
        for report in results.values {
            #expect(report.visibleActions == Array(["ext0", "ext1", "ext2", "ext3"].prefix(report.visibleActions.count)))
        }
    }

    @Test func overflowedActionAnchorsToTheExtensionsButton() async throws {
        let wide = Harness(width: 1400)
        await wide.settle()
        wide.chrome.runExtensionAction("ext1")
        let report = wide.chrome.toolbarReport
        #expect(report.openPopup == "ext1")
        #expect(report.popupAnchor == report.frames["action:ext1"])

        let narrow = Harness(width: 320)
        await narrow.settle()
        narrow.chrome.runExtensionAction("ext1")
        let collapsed = narrow.chrome.toolbarReport
        #expect(collapsed.overflowActions.contains("ext1"))
        #expect(collapsed.popupAnchor == collapsed.frames["extensions"])
    }

    @Test func resizingThePaneClosesTheOpenPopup() async {
        let h = Harness(width: 800)
        await h.settle()
        h.chrome.runExtensionAction("ext0")
        #expect(h.tab.openExtensionPopup == "ext0")
        h.window.setContentSize(NSSize(width: 500, height: 240))
        await h.settle()
        #expect(h.tab.openExtensionPopup == nil)
    }

    @Test func pinningFromTheStoreAddsAButton() async {
        let h = Harness(width: 1400, pinned: 1)
        await h.settle()
        #expect(h.chrome.toolbarReport.visibleActions == ["ext0"])
        #expect(h.tab.extensionStore.setPinned("ext4", true))
        await h.settle()
        #expect(h.chrome.toolbarReport.visibleActions == ["ext0", "ext4"])
        #expect(h.tab.extensionStore.setPinned("ext0", false))
        await h.settle()
        #expect(h.chrome.toolbarReport.visibleActions == ["ext4"])
    }

    @Test func menuRowsAndOperations() {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        tab.installMockExtensions([
            BrowserExtensionInfo(id: "a", name: "Alpha", hasAction: true, isPinned: true, optionsURL: URL(string: "chrome-extension://a/o.html")),
            BrowserExtensionInfo(id: "b", name: "Beta", isEnabled: false, hasAction: true),
            BrowserExtensionInfo(id: "c", name: "Policy", hasAction: true, mayModify: false),
        ])
        let handler = RecordingHandler()
        let menu = ExtensionsMenu.make(for: tab, handler: handler, afterClose: { $0() }, presentItemMenu: { _ in })
        let rows = menu.items.compactMap { $0.representedObject as? String }
        #expect(rows == ["a", "c", "b"])
        #expect(ExtensionMenuDriver.choose("run", extension: "a", in: menu))
        #expect(ExtensionMenuDriver.choose("unpin", extension: "a", in: menu))
        #expect(ExtensionMenuDriver.choose("manage", extension: nil, in: menu))
        #expect(handler.performed.map(\.0) == [.run, .unpin, .manage])
        #expect(ExtensionsMenu.operations(for: tab.extensionStore.extensions[0], supportsManagement: true)
            == [.run, .unpin, .options, .disable, .siteAccess, .remove])
        #expect(ExtensionsMenu.operations(for: tab.extensionStore.extensions[1], supportsManagement: true) == [.enable, .remove])
        #expect(ExtensionsMenu.operations(for: tab.extensionStore.extensions[2], supportsManagement: true) == [.run, .pin, .siteAccess])
    }

    @Test func dragReordersPinnedButtons() async {
        let h = Harness(width: 1400)
        await h.settle()
        let step = OmnibarStyle.buttonSize + BrowserMetrics.buttonSpacing
        #expect(h.chrome.extensionToolbar.dragTarget("ext0", dx: step * 2.2) == 2)
        #expect(h.chrome.extensionToolbar.dragTarget("ext3", dx: -step * 9) == 0)
        #expect(h.chrome.extensionToolbar.dragTarget("ext1", dx: 1) == 1)
        #expect(h.chrome.moveExtensionAction("ext0", to: 2))
        await h.settle()
        #expect(h.chrome.toolbarReport.visibleActions == ["ext1", "ext2", "ext0", "ext3"])
        // An unpinned extension cannot move among the pinned ones.
        #expect(!h.chrome.moveExtensionAction("ext5", to: 0))
    }

    @Test func crashedOrUnpackedExtensionsOfferReload() {
        let crashed = BrowserExtensionInfo(id: "c", name: "Crashed", isTerminated: true, hasAction: true)
        let unpacked = BrowserExtensionInfo(id: "u", name: "Dev", location: .unpacked, hasAction: true)
        let store = BrowserExtensionInfo(id: "s", name: "Store", location: .webstore, hasAction: true)
        #expect(ExtensionsMenu.operations(for: crashed, supportsManagement: true).contains(.reload))
        #expect(ExtensionsMenu.operations(for: unpacked, supportsManagement: true).contains(.reload))
        #expect(!ExtensionsMenu.operations(for: store, supportsManagement: true).contains(.reload))
        #expect(!ExtensionsMenu.operations(for: crashed, supportsManagement: false).contains(.reload))
    }

    final class RecordingHandler: ExtensionMenuHandling {
        var performed: [(ExtensionMenuOperation, String?)] = []
        func title(for operation: ExtensionMenuOperation) -> String { operation.rawValue }
        func perform(_ operation: ExtensionMenuOperation, extensionID: String?) { performed.append((operation, extensionID)) }
    }

    /// With `EXTENSIONS_SNAPSHOT_DIR` set, writes the toolbar at each width
    /// (bare and in a 12 pt padded pane, light and dark) for visual review.
    @Test func snapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["EXTENSIONS_SNAPSHOT_DIR"] else { return }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in Self.widths {
                for padding in [CGFloat(0), 12] {
                    let h = Harness(width: width, padding: padding)
                    h.window.appearance = NSAppearance(named: appearance)
                    await h.settle()
                    let view = h.container
                    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let crop = NSRect(x: 0, y: 0, width: view.bounds.width, height: 56 + 2 * padding)
                    let image = NSImage(size: crop.size)
                    image.lockFocus()
                    NSColor(white: name == "dark" ? 0.2 : 0.8, alpha: 1).setFill()
                    crop.fill()
                    rep.draw(in: NSRect(x: 0, y: crop.height - view.bounds.height, width: view.bounds.width, height: view.bounds.height))
                    image.unlockFocus()
                    let tiff = try #require(image.tiffRepresentation)
                    let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: "\(directory)/toolbar-\(Int(width))-pad\(Int(padding))-\(name).png"))
                }
            }
        }
    }
}
