import AppKit
@testable import CmuxNextApp
import CmuxNextHibernation
@testable import CmuxNextBridge
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing
import CmuxNextTestSupport

/// The 2026-10-14 hibernation audit (100 Chromium tabs, `browser.hibernation` 0.5 min): 34
/// renderers (2.9 GB) outlived their tabs' pages, and the app grew about 7 MB per hibernated tab.
/// The renderers were live pages that never hibernated: 7 of the 20 sites (Wikipedia, the Python
/// docs, OpenStreetMap, apple.com) fill a form field from script or show a `<select>` with no
/// default option, and the probe called that the person's form input. The 7 MB was each
/// placeholder's own full-size snapshot, outside the 32 MB preview cache. Real WebKit pages,
/// hidden from a pane, through the app's hibernation.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct HiddenPageHibernationTests {
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
        _ = try await page.evaluate("document.getElementById('note').focus(); true", world: .page, gesture: .agent)
        page.webView.insertText("draft")
        try await rig.until("the typing reached the page") {
            (try? await page.evaluate("document.getElementById('note').value", world: .page, gesture: .agent)) == .string("draft")
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
        _ = try await page.evaluate("document.getElementById('note').focus(); true", world: .page, gesture: .agent)
        page.webView.insertText("draft")
        try await rig.until("the typing reached the page") {
            (try? await page.evaluate("document.getElementById('note').value", world: .page, gesture: .agent)) == .string("draft")
        }
        rig.window.contentView = nil
        let key = try await rig.hide(page)
        try await rig.until("the page was kept") { rig.exemption(key) != nil }
        try #require(rig.exemption(key) == .formInput)

        // The draft is gone (sent, cleared): the next look lets the page hibernate.
        _ = try await page.evaluate("document.getElementById('note').value = ''; true", world: .page, gesture: .agent)
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
        _ = try await page.evaluate("document.getElementById('s').value = 'b'; true", world: .page, gesture: .agent)
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
        _ = try await page.evaluate("document.getElementById('editor').textContent = ''; true", world: .page, gesture: .agent)
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
        let store = rig.hibernation.snapshots
        #expect(store.count == 1 && store.totalBytes <= store.capacityBytes / 4, "one snapshot takes \(store.totalBytes >> 20) MB of the store")
        // #20866 second review: the page's colors and shape (PR 23083: kept at its size, compressed).
        #expect(snapshot.colorSpace?.isWideGamutRGB == true, "the snapshot lost the page's wide-gamut color space")
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

    @Test func hibernatedPagesKeepNoMoreSnapshotBytesThanTheirStore() async throws {
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
        let store = rig.hibernation.snapshots
        #expect(store.count == keys.count && store.totalBytes <= store.capacityBytes,
                "hibernated pages hold \(store.totalBytes >> 20) MB of snapshots, over the \(store.capacityBytes >> 20) MB store")
        #expect(rig.services.cache.previews.count == 0, "a hibernated page's decoded picture went to the shared preview cache")
        let last = try #require(rig.services.cache.browsers[keys[keys.count - 1]]?.tab as? HibernatedBrowserTab)
        #expect(last.snapshotImage != nil, "the latest hibernated page lost its snapshot")
    }

    /// PR 23083 (Leo: wake from a snapshot): each picture was scaled to a quarter of the shared
    /// 32 MB preview cache, so only the last four hibernated pages kept one and every other tab
    /// woke to an empty pane.
    @Test func everyHibernatedPageKeepsItsSnapshot() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var keys: [String] = []
        for index in 0..<8 {
            let page = try await rig.page("kept\(index)", body: "<p>page \(index)</p>")
            let picture = try Self.picture(shade: Double(index) / 8)
            rig.hibernation.capture = { _ in picture }
            let key = try await rig.hide(page)
            try await rig.until("page \(index) hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
            try #require(rig.isHibernated(key))
            keys.append(key)
        }
        for (index, key) in keys.enumerated() {
            let snapshot = (rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)?.snapshotImage
            #expect(snapshot != nil, "hibernated page \(index) of \(keys.count) lost its snapshot")
        }
    }

    /// The snapshot store keeps its budget: the least recently used picture goes first.
    @Test func theSnapshotStoreDropsTheLeastRecentlyUsedPicturePastItsBudget() async throws {
        let one = try #require(await HibernationSnapshots.compress(Self.noise(seed: 1)))
        let size = try #require(one.data?.count)
        let store = HibernationSnapshots(capacityBytes: size * 5 / 2)
        store.insert(one, for: "a")
        store.insert(try #require(await HibernationSnapshots.compress(Self.noise(seed: 2))), for: "b")
        _ = store.image(for: "a")  // "a" is used again: "b" is now the oldest
        store.insert(try #require(await HibernationSnapshots.compress(Self.noise(seed: 3))), for: "c")
        #expect(store.image(for: "a") != nil && store.image(for: "c") != nil, "a recently used picture was dropped")
        #expect(store.image(for: "b") == nil, "the least recently used picture stayed past the budget")
        #expect(store.totalBytes <= store.capacityBytes)
    }

    /// Each wake is timed for `debug.surfaces` and the bench: shown with its snapshot, back, then loaded.
    @Test func aWakeIsTimedWithItsSnapshot() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let picture = try Self.picture(shade: 0.4, width: 1200, height: 800)
        rig.hibernation.capture = { _ in picture }
        let key = try await rig.hide(rig.page("timed", body: "<p>timed</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the woken page loaded") { rig.hibernation.wakeLog.records.last?.loadedMs != nil }
        let wake = try #require(rig.hibernation.wakeLog.records.last)
        #expect(wake.tab == key && wake.engine == .webkit && wake.visible, "the wake was not the shown page's: \(wake)")
        #expect(wake.snapshot, "the pane had no snapshot while the page came back")
        #expect((wake.mountedMs ?? .max) <= (wake.loadedMs ?? 0), "the page loaded before it was back: \(wake)")
        #expect(rig.hibernation.snapshots.count == 0, "the woken page's snapshot stayed in the store")
    }

    /// Leo (PR 23083): a hibernated page comes back where it was, with what its fields held.
    @Test func aWokenPageHasItsScrollAndFormBack() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let page = try await rig.page("state", body: """
            <input id="name"><textarea id="notes"></textarea><div style="height: 8000px">long</div>
            """)
        rig.window.contentView = page.contentView  // laid out at the window's size, as in a pane
        _ = try await page.evaluate("""
            document.getElementById('name').value = 'Ada'; document.getElementById('notes').value = 'two\\nlines';
            window.scrollTo(0, 3000); true
            """, world: .page, gesture: .agent)
        // WebKit writes the scroll position into the page's history item once scrolling has
        // stopped for a moment; a person's page hibernates minutes later.
        try await Task.sleep(for: .seconds(1))
        // A pane parks the page it stops showing hidden in the window (`PaneContentView.retire`);
        // WebKit then saves the page's fields into its history item (the state hibernation keeps).
        // It saves them only when the page goes from shown to hidden: a host whose window is never
        // on screen (a CI mini's console) gets the scroll back but not the fields, which
        // scripts/cmux-next/bench_hibernation.py checks on a capture mini.
        let shown = rig.window.occlusionState.contains(.visible)
        page.contentView.isHidden = true
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        let state = "JSON.stringify([document.getElementById('name')?.value, document.getElementById('notes')?.value, Math.round(window.scrollY)])"
        var seen = "no page"
        try await rig.until("the woken page has its state back (it has \(seen))") {
            guard let woken = rig.services.cache.browsers[key]?.tab as? WebKitTab else { return false }
            if rig.window.contentView !== woken.contentView { rig.window.contentView = woken.contentView }
            let value = try? await woken.evaluate(state, world: .page, gesture: .agent)
            seen = String(describing: value)
            return value == .string(shown ? #"["Ada","two\nlines",3000]"# : #"["","",3000]"#)
        }
    }

    /// An image JPEG cannot squeeze much (a page picture's real cost, unlike a flat color).
    private static func noise(seed: UInt64, width: Int = 400, height: Int = 300) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        let pixels = try #require(context.data?.bindMemory(to: UInt32.self, capacity: width * height))
        for index in 0..<(width * height) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt32(truncatingIfNeeded: state >> 32)
        }
        return try #require(context.makeImage())
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
    /// is due at once: `hide` moves the hibernation's clock past the pressure's minimum hidden
    /// time), with one pane that shows and hides pages.
    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let pane = Pane()
        let folder: URL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        var keys: [String] = []
        /// How far the hibernation's clock (`BrowserHibernation.now`) runs ahead of the wall clock.
        var skipped: Duration = .zero

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()))
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .moderate))
            hibernation.pressureDidChange(.critical)
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-hidden-hibernation-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            window.isReleasedWhenClosed = false
            var completed = false
            defer { if !completed { close() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            window.orderFrontRegardless()
            hibernation.now = { [weak self] in .now + (self?.skipped ?? .zero) }
            // No test here checks a page that does not answer (UnansweredPageProbeTests does): a probe
            // starved past its 2 s by a full parallel run would keep the page as `unanswered`, and
            // nothing would ask it again.
            hibernation.pageDeadline = .seconds(120)
            completed = true
        }

        /// A loaded WebKit page showing `body`, titled `name`.
        func page(_ name: String, body: String) async throws -> WebKitTab {
            let url = folder.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title>\(body)".write(to: url, atomically: true, encoding: .utf8)
            let page = services.cache.webKit.makeWebKitTab()
            page.load(url)
            try await until("\(name) loads") {
                (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string(name)
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
            // Critical pressure takes only a page hidden `Pace.critical.minimumHidden` (10 s; the
            // person may come straight back). Waiting that out on the wall clock put a 10 s timer
            // inside every 15 s wait for a hibernation, which a starved parallel run overran:
            // the page is that old now, and planned at once.
            if hibernation.pressure == .critical {
                skipped += .seconds(HibernationPlanner.Pace.critical.minimumHidden)
                hibernation.replan()
            }
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
                (try? await page.evaluate("window.pressed === true", world: .page, gesture: .agent)) == .bool(true)
            }
        }

        /// Types `text` into the empty rich editor `id` as the person would. The page stays in the window.
        func type(_ text: String, into id: String, _ page: WebKitTab) async throws {
            window.contentView = page.contentView
            window.makeFirstResponder(page.webView)
            _ = try await page.evaluate("document.getElementById('\(id)').focus(); true", world: .page, gesture: .agent)
            page.webView.insertText(text)
            try await until("the typing reached the editor") {
                (try? await page.evaluate("document.getElementById('\(id)').textContent", world: .page, gesture: .agent)) == .string(text)
            }
        }

        func isHibernated(_ key: String) -> Bool { services.cache.browsers[key]?.tab is HibernatedBrowserTab }
        func exemption(_ key: String) -> HibernationPlanner.Exemption? { hibernation.exemptions[key] }

        /// Polls `condition` every 25 ms until it holds. The budget is a count of idle polls (15 s on
        /// an idle machine), not a wall-clock deadline: in the full parallel CmuxNextAppTests run the
        /// main actor and the pages' content processes are starved (tests that do nothing took
        /// over 300 s), so the wait stretches with the load instead of running out. A poll while the
        /// hibernation asks a page (a discard probe with its snapshot and `beforeunload`, or a freeze
        /// probe, each bounded by `pageDeadline`) is not idle: the page is still on its way to
        /// hibernating, freezing or being kept, however slowly its content process answers. A
        /// condition that never holds still fails.
        func until(_ what: @autoclosure () -> String, _ condition: () async -> Bool) async throws {
            var idle = 0
            while idle < Self.polls {
                if await condition() { return }
                if hibernation.probing.isEmpty, hibernation.freezeProbing.isEmpty { idle += 1 }
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(await condition(), "\(what()) never happened")
        }

        static let polls = 600

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
