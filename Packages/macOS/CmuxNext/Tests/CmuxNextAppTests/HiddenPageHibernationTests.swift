import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextSettings
import Foundation
import Testing

/// The 2026-10-14 hibernation audit (100 Chromium tabs, `browser.hibernation` 0.5 min): 34
/// renderers (2.9 GB) outlived their tabs' pages, and the app grew about 7 MB per hibernated tab.
/// The renderers were live pages that never hibernated: 7 of the 20 sites (Wikipedia, the Python
/// docs, OpenStreetMap, apple.com) fill a form field from script or show a `<select>` with no
/// default option, and the probe called that the person's form input. The 7 MB was each
/// placeholder's own full-size snapshot, outside the 32 MB preview cache. Real WebKit pages,
/// hidden from a pane, through the app's hibernation.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HiddenPageHibernationTests {
    @Test func aPageWhoseScriptFillsItsFormHibernates() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("scripted", body: """
            <select id="engine"><option>Car</option><option>Bike</option></select>
            <input type="radio" name="size" value="small"><input type="radio" name="size" value="large">
            <div id="versions"></div>
            <script>
            const versions = document.createElement('select');
            for (const v of ['3.13', '3.14']) {
              const option = document.createElement('option');
              option.textContent = v;
              option.selected = v === '3.14';
              versions.append(option);
            }
            document.getElementById('versions').append(versions);
            document.querySelector('input[value=large]').checked = true;
            </script>
            """))
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == nil, "a page whose script filled its fields was kept as form input")
        #expect(rig.isHibernated(key), "the hidden page kept its engine page")
    }

    @Test func aPageThePersonTypedIntoKeepsItsPage() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("typed", body: "<input id='note'>")
        rig.window.contentView = page.contentView
        rig.window.makeFirstResponder(page.webView)
        _ = try await page.evaluate("document.getElementById('note').focus(); true", world: .page)
        page.webView.insertText("draft")
        try await rig.until("the typing reached the page") {
            (try? await page.evaluate("document.getElementById('note').value", world: .page)) == .string("draft")
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .formInput, "a page with the person's typing hibernated")
    }

    /// The 2026-10-14 audit rerun: `debug.surfaces` listed hibernated Chromium tabs as kept for
    /// audio. A probe that keeps a page records why; when a later probe lets the page hibernate,
    /// that reason has to go with it, or the report says a hibernated page was kept.
    @Test func aPageKeptOnceThenHibernatedIsNoLongerReportedAsKept() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("cleared", body: "<input id='note'>")
        rig.window.contentView = page.contentView
        rig.window.makeFirstResponder(page.webView)
        _ = try await page.evaluate("document.getElementById('note').focus(); true", world: .page)
        page.webView.insertText("draft")
        try await rig.until("the typing reached the page") {
            (try? await page.evaluate("document.getElementById('note').value", world: .page)) == .string("draft")
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page was kept") { rig.exemption(key) != nil }
        try #require(rig.exemption(key) == .formInput)

        // The draft is gone (sent, cleared): the next look lets the page hibernate.
        _ = try await page.evaluate("document.getElementById('note').value = ''; true", world: .page)
        rig.hibernation.replan()
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        #expect(rig.exemption(key) == nil, "a hibernated page is still reported as kept")
    }

    /// #20866 review: a person who used the page and then let a widget or the page's script set a
    /// field (a date picker, a Select2 menu, a draft re-rendered through `.value`) still has edits
    /// there, though no trusted input event touched the field.
    @Test func aPageThePersonUsedWhoseScriptThenSetAFieldKeepsItsPage() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("used", body: """
            <select id="s"><option value="a" selected>A</option><option value="b">B</option></select>
            <div style="height: 2000px"></div>
            <script>addEventListener('keydown', (e) => { window.pressed = e.isTrusted; }, true);</script>
            """)
        try await rig.pressDown(page)
        _ = try await page.evaluate("document.getElementById('s').value = 'b'; true", world: .page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .formInput, "a page the person used, with a changed field, hibernated")
    }

    /// #20866 second review: selecting text or pressing a key on a docs page is use, but the fields
    /// its script filled at load are not the person's: the page still hibernates.
    @Test func aPageThePersonOnlyUsedWhoseScriptFilledItsFormHibernates() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("browsed", body: """
            <div id="versions"></div>
            <input type="radio" name="size" value="small"><input type="radio" name="size" value="large">
            <div style="height: 2000px"></div>
            <script>
            const versions = document.createElement('select');
            for (const v of ['3.13', '3.14']) {
              const option = document.createElement('option');
              option.textContent = v;
              option.selected = v === '3.14';
              versions.append(option);
            }
            document.getElementById('versions').append(versions);
            document.querySelector('input[value=large]').checked = true;
            addEventListener('keydown', (e) => { window.pressed = e.isTrusted; }, true);
            </script>
            """)
        try await rig.pressDown(page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == nil, "a page the person only read was kept for the fields its script filled")
        #expect(rig.isHibernated(key))
    }

    /// #20866 second review: a composer the person typed in and then sent (a chat app clears it)
    /// holds nothing to lose: the page hibernates.
    @Test func aRichEditorThePersonClearedLetsThePageHibernate() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("sent", body: "<div id='editor' contenteditable style='height: 200px'></div>")
        try await rig.type("draft", into: "editor", page)
        _ = try await page.evaluate("document.getElementById('editor').textContent = ''; true", world: .page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == nil, "a page whose editor was cleared after sending was kept")
        #expect(rig.isHibernated(key))
    }

    /// #20866 review: a rich text editor (a mail compose, a comment box) is no form field.
    @Test func aPageThePersonTypedIntoARichEditorKeepsItsPage() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("editor", body: "<div id='editor' contenteditable style='height: 200px'></div>")
        try await rig.type("draft", into: "editor", page)
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated or was kept") { rig.isHibernated(key) || rig.exemption(key) != nil }
        #expect(rig.exemption(key) == .formInput, "a page with the person's typing in a rich editor hibernated")
    }

    /// #20866 review: a 2560 x 1600 pt pane at 2x is about 65 MB, more than the whole 32 MB cache,
    /// which never took it: the tab woke blank.
    @Test func aLargePaneStillHasASnapshotAfterHibernating() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let large = try Self.picture(shade: 0.5, width: 5120, height: 3200, space: p3)
        rig.hibernation.capture = { _ in large }
        let key = try await rig.hide(rig.page("large", body: "<p>large</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        let snapshot = try #require((rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)?.snapshotImage,
                                    "a large pane's page hibernated without a snapshot")
        #expect(PreviewImageCache.cost(snapshot) <= rig.services.cache.previews.capacityBytes / 4, "one snapshot takes over a quarter of the cache")
        // #20866 second review: the page's colors and shape, only smaller.
        #expect(snapshot.colorSpace?.name == CGColorSpace.displayP3, "the snapshot lost the page's color space")
        #expect(abs(Double(snapshot.width) / Double(snapshot.height) - 1.6) < 0.005, "the snapshot was squeezed to \(snapshot.width) x \(snapshot.height)")
    }

    /// #20866 review: a page that woke and hibernated again showed the picture of its first sleep.
    @Test func aPageThatHibernatesAgainShowsItsNewSnapshot() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let first = try Self.picture(shade: 0.2, width: 1000, height: 700)
        rig.hibernation.capture = { _ in first }
        let key = try await rig.hide(rig.page("twice", body: "<p>twice</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))

        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page woke") { !rig.isHibernated(key) && rig.services.cache.phase(of: key) == .mountedVisible }
        let second = try Self.picture(shade: 0.8, width: 900, height: 600)
        rig.hibernation.capture = { _ in second }
        rig.services.cache.withdraw(key, by: rig.pane)
        try await rig.until("the page hibernated again") { rig.isHibernated(key) || rig.exemption(key) != nil }
        let snapshot = (rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)?.snapshotImage
        #expect(snapshot?.width == 900, "the page showed the picture of its first sleep")
    }

    @Test func hibernatedPagesKeepNoMoreSnapshotsThanThePreviewCache() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var keys: [String] = []
        for index in 0..<8 {
            let page = try await rig.page("plain\(index)", body: "<p>page \(index)</p>")
            // The page's full-size picture (2048 x 1536, 12 MB).
            let picture = try Self.picture(shade: Double(index) / 8)
            rig.hibernation.capture = { _ in picture }
            let key = try await rig.hide(page)
            try await rig.until("page \(index) hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
            #expect(rig.isHibernated(key))
            keys.append(key)
        }
        let held = keys.compactMap { (rig.services.cache.browsers[$0]?.tab as? HibernatedBrowserTab)?.snapshotImage }
            .reduce(0) { $0 + PreviewImageCache.cost($1) }
        #expect(held <= rig.services.cache.previews.capacityBytes,
                "hibernated pages hold \(held >> 20) MB of snapshots, over the \(rig.services.cache.previews.capacityBytes >> 20) MB cache")
        let last = try #require(rig.services.cache.browsers[keys[keys.count - 1]]?.tab as? HibernatedBrowserTab)
        #expect(last.snapshotImage != nil, "the latest hibernated page lost its snapshot")
    }

    private static func picture(shade: Double, width: Int = 2048, height: Int = 1536,
                                space: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The app's tab content cache and hibernation, under critical memory pressure (a hidden page
    /// is due at once), with one pane that shows and hides pages.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let pane = Pane()
        let folder: URL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        var keys: [String] = []

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache)
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .moderate))
            hibernation.pressureDidChange(.critical)
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-hidden-hibernation-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
        }

        /// A loaded WebKit page showing `body`, titled `name`.
        func page(_ name: String, body: String) async throws -> WebKitTab {
            let url = folder.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title>\(body)".write(to: url, atomically: true, encoding: .utf8)
            let page = services.cache.webKit.makeWebKitTab()
            page.load(url)
            try await until("\(name) loads") {
                (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page)) == .string(name)
            }
            return page
        }

        /// Installs `page` as a tab's content, shows it in the pane, then hides it.
        func hide(_ page: WebKitTab) async throws -> String {
            let key = page.id.rawValue
            keys.append(key)
            services.cache.install(page, for: key)
            services.cache.present(key, by: pane, presence: .visible)
            try #require(services.cache.phase(of: key) == .mountedVisible)
            services.cache.withdraw(key, by: pane)
            try #require(services.cache.phase(of: key) == .mountedHidden)
            return key
        }

        /// A Down arrow on the page (it must note `window.pressed` on keydown): the person used
        /// it, and no field changed. The page stays in the window.
        func pressDown(_ page: WebKitTab) async throws {
            window.contentView = page.contentView
            window.makeFirstResponder(page.webView)
            let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
            page.webView.keyDown(with: down)
            try await until("the key reached the page") {
                (try? await page.evaluate("window.pressed === true", world: .page)) == .bool(true)
            }
        }

        /// Types `text` into the empty rich editor `id` as the person would. The page stays in the window.
        func type(_ text: String, into id: String, _ page: WebKitTab) async throws {
            window.contentView = page.contentView
            window.makeFirstResponder(page.webView)
            _ = try await page.evaluate("document.getElementById('\(id)').focus(); true", world: .page)
            page.webView.insertText(text)
            try await until("the typing reached the editor") {
                (try? await page.evaluate("document.getElementById('\(id)').textContent", world: .page)) == .string(text)
            }
        }

        func isHibernated(_ key: String) -> Bool { services.cache.browsers[key]?.tab is HibernatedBrowserTab }
        func exemption(_ key: String) -> HibernationPlanner.Exemption? { hibernation.exemptions[key] }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what) never happened")
        }

        func close() {
            for key in keys { services.cache.release(key) }
            hibernation.stop()
            window.orderOut(nil)
            window.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
