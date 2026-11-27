import CmuxTabsKit
import Observation
import SwiftUI
import WebKit

/// The demo's data source: local web pages (WKWebView) and a "note" tab
/// kind written in SwiftUI.
@MainActor
@Observable
final class DemoTabs: TabsDataSource {
    static let note: TabsKitTabKind = "note"

    private var order: [String] = []
    private var webPages: [String: DemoWebPage] = [:]
    private var notes: [String: String] = [:]
    private var thumbnails: [String: UIImage] = [:]
    private(set) var activeTabID: String?
    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private let configuration: WKWebViewConfiguration = {
        let c = WKWebViewConfiguration()
        c.setURLSchemeHandler(DemoSchemeHandler(), forURLScheme: DemoSite.scheme)
        return c
    }()

    let newTabOptions = [
        TabsKitNewTabOption(id: "web", title: "New Tab", systemImage: "globe", kind: .web),
        TabsKitNewTabOption(id: "note", title: "New Note", systemImage: "note.text", kind: DemoTabs.note),
    ]

    /// Verification hooks (launch arguments): `-tabCount N` starts with N web
    /// pages (0 and 50 included) instead of the default set; `-failCreate`
    /// refuses every new tab; `-failClose` refuses every close.
    private let failCreate = ProcessInfo.processInfo.arguments.contains("-failCreate")
    private let failClose = ProcessInfo.processInfo.arguments.contains("-failClose")
    private(set) var notice: String?

    init() {
        let args = ProcessInfo.processInfo.arguments
        let names = ["springs", "glass", "pinch", "night"]
        if let i = args.firstIndex(of: "-tabCount"), i + 1 < args.count, let n = Int(args[i + 1]) {
            for k in 0..<max(0, n) { addWebPage(URL(string: "tabskit://pages/\(names[k % names.count])")!) }
        } else {
            for name in names { addWebPage(URL(string: "tabskit://pages/\(name)")!) }
            addNote("Notes are plain SwiftUI tabs.\n\nThey get the same grid, zoom, swipe and toolbar as web pages, with their own card, page menu and an accessory row above the toolbar.")
        }
        activeTabID = order.first
    }

    func clearNotice() { notice = nil }

    // MARK: TabsDataSource

    var tabs: [TabsKitTab] { order.compactMap(tab(for:)) }

    func activate(_ id: String) {
        guard id != activeTabID, order.contains(id) else { return }
        if let old = activeTabID { refreshThumbnail(old) }
        activeTabID = id
    }

    func close(_ id: String) async -> Bool {
        guard let index = order.firstIndex(of: id) else { return true }
        if failClose {
            notice = "Couldn't close \(tab(for: id)?.title ?? "the tab"): the demo refuses closes (-failClose)."
            return false
        }
        order.remove(at: index)
        webPages[id] = nil
        notes[id] = nil
        thumbnails[id] = nil
        if activeTabID == id { activeTabID = order.isEmpty ? nil : order[min(index, order.count - 1)] }
        return true
    }

    func createTab(_ option: TabsKitNewTabOption) async -> String? {
        if failCreate {
            notice = "Couldn't open a new tab: the demo refuses new tabs (-failCreate)."
            return nil
        }
        let id = option.kind == Self.note ? addNote("") : addWebPage(DemoSite.start)
        activate(id)
        return id
    }

    @ViewBuilder func content(for tab: TabsKitTab, context: TabsKitContentContext) -> some View {
        if let page = webPages[tab.id] {
            DemoWebView(page: page, context: context)
        } else {
            NotePage(text: noteBinding(tab.id), context: context)
        }
    }

    @ViewBuilder func card(for tab: TabsKitTab) -> some View {
        if let text = notes[tab.id] {
            NotePage(text: .constant(text), context: nil)
        } else if let page = webPages[tab.id], page.url == nil || page.url == DemoSite.start {
            // Drawn natively, so a new tab's start page shows from the first
            // frame of its zoom (the web view draws nothing until it is on
            // screen and loaded).
            DemoStartCard()
        } else {
            TabsKitThumbnailCard(tab: tab, image: thumbnails[tab.id])
        }
    }

    func thumbnail(for id: String) -> UIImage? { thumbnails[id] }

    func overviewWillAppear() {
        if let id = activeTabID { refreshThumbnail(id) }
    }

    @ViewBuilder func accessory(for tab: TabsKitTab, context: TabsKitContentContext) -> some View {
        if let text = notes[tab.id] {
            NoteAccessory(words: text.split { $0.isWhitespace || $0.isNewline }.count) { [weak self] in self?.notes[tab.id] = "" }
        }
    }

    func goBack(_ id: String) { webPages[id]?.webView.goBack() }
    func goForward(_ id: String) { webPages[id]?.webView.goForward() }
    var providesHistoryMenus: Bool { true }
    func history(_ direction: TabsKitHistoryDirection, for id: String) -> [TabsKitHistoryItem] {
        webPages[id]?.history(direction) ?? []
    }
    func goToHistoryItem(_ item: TabsKitHistoryItem, in id: String) { webPages[id]?.go(to: item) }

    func navigate(_ id: String, to text: String) {
        guard let page = webPages[id], let url = DemoSite.url(for: text) else { return }
        page.webView.load(URLRequest(url: url))
    }

    func reloadOrStop(_ id: String) {
        guard let web = webPages[id]?.webView else { return }
        if web.isLoading { web.stopLoading() } else { web.reload() }
    }

    func pageMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]] {
        if notes[tab.id] != nil {
            return [[
                TabsKitMenuItem(title: "Clear Note", systemImage: "eraser") { [weak self] in self?.notes[tab.id] = "" },
                TabsKitMenuItem(title: "Close Note", systemImage: "xmark.square", isDestructive: true) { [weak self] in Task { _ = await self?.close(tab.id) } },
            ]]
        }
        let web = webPages[tab.id]?.webView
        return [
            [
                TabsKitMenuItem(title: tab.navigation.isLoading ? "Stop Loading" : "Reload",
                                systemImage: tab.navigation.isLoading ? "xmark" : "arrow.clockwise") { [weak self] in self?.reloadOrStop(tab.id) },
                TabsKitMenuItem(title: "Copy URL", systemImage: "doc.on.doc", isEnabled: web?.url != nil) {
                    UIPasteboard.general.string = web?.url?.absoluteString
                },
            ],
            [
                TabsKitMenuItem(title: "Close Tab", systemImage: "xmark.square") { [weak self] in Task { _ = await self?.close(tab.id) } },
            ],
        ]
    }

    // MARK: Model

    /// A card's long-press menu: Copy Link and Duplicate Tab for web pages
    /// (the kit adds Close Tab and Close Other Tabs).
    func cardMenu(for tab: TabsKitTab) -> [[TabsKitMenuItem]] {
        guard let url = webPages[tab.id]?.webView.url else { return [] }
        return [[
            TabsKitMenuItem(title: "Copy Link", systemImage: "link") { UIPasteboard.general.url = url },
            TabsKitMenuItem(title: "Duplicate Tab", systemImage: "plus.square.on.square") { [weak self] in
                guard let self, let i = self.order.firstIndex(of: tab.id) else { return }
                let id = self.addWebPage(url)
                self.moveTab(id, to: i + 1)
            },
        ]]
    }

    var supportsReordering: Bool { true }

    /// Pinned tabs come first in `order` (Safari's pinned area).
    private(set) var pinnedTabIDs: Set<String> = []
    var supportsPinning: Bool { true }

    func setPinned(_ ids: [String], _ pinned: Bool) {
        for id in ids { if pinned { pinnedTabIDs.insert(id) } else { pinnedTabIDs.remove(id) } }
        let pins = order.filter { pinnedTabIDs.contains($0) }
        order = pins + order.filter { !pinnedTabIDs.contains($0) }
    }

    func links(for ids: [String]) -> [URL] { ids.compactMap { webPages[$0]?.webView.url } }

    func moveTab(_ id: String, to index: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: max(0, min(index, order.count)))
    }

    /// A start page loaded ahead, so a new tab shows its page from the first
    /// frame of the zoom (a fresh web view drew nothing for about 300 ms).
    @ObservationIgnored private var spareStart: DemoWebPage?

    private func prepareSpareStart() {
        if spareStart == nil { spareStart = DemoWebPage(url: DemoSite.start, configuration: configuration) }
    }

    @discardableResult
    private func addWebPage(_ url: URL) -> String {
        let id = makeId()
        let page: DemoWebPage
        if url == DemoSite.start, let spare = spareStart {
            page = spare
            spareStart = nil
        } else {
            page = DemoWebPage(url: url, configuration: configuration)
        }
        defer { prepareSpareStart() }
        page.onLoaded = { [weak self] in self?.refreshThumbnail(id) }
        if !page.isLoading { DispatchQueue.main.async { [weak self] in self?.refreshThumbnail(id) } }
        webPages[id] = page
        order.append(id)
        return id
    }

    @discardableResult
    private func addNote(_ text: String) -> String {
        let id = makeId()
        notes[id] = text
        order.append(id)
        return id
    }

    private func makeId() -> String {
        nextId += 1
        return "tab-\(nextId)"
    }

    private func tab(for id: String) -> TabsKitTab? {
        if let page = webPages[id] { return page.tab(id: id) }
        guard let text = notes[id] else { return nil }
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return TabsKitTab(id: id, kind: Self.note, title: "Note", subtitle: "\(words) words", systemImage: "note.text",
                          address: .title("Note", subtitle: words == 1 ? "1 word" : "\(words) words"), features: [.pageMenu])
    }

    private func noteBinding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.notes[id] ?? "" }, set: { [weak self] in self?.notes[id] = $0 })
    }

    /// Snapshots a web tab's page for its card (only meaningful while its
    /// web view is on screen; others keep their last snapshot).
    private func refreshThumbnail(_ id: String) {
        guard let page = webPages[id], page.webView.window != nil else { return }
        Task {
            if let image = await page.snapshot() { thumbnails[id] = image }
        }
    }
}

/// A note: a title and a multi-line text field, laid out at full screen.
/// `context` is nil when drawn as a card.
struct NotePage: View {
    @Binding var text: String
    var context: TabsKitContentContext?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Note").font(.largeTitle.bold())
                TextField("Write something", text: $text, axis: .vertical)
                    .font(.system(size: 19))
                    .disabled(context == nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, (context?.safeAreaInsets.top ?? 62) + 16)
            .padding(.bottom, (context?.safeAreaInsets.bottom ?? 100) + 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(red: 1, green: 0.98, blue: 0.88))
        .foregroundStyle(.black)
        .modifier(ReportsScroll(context: context))
    }
}

private struct ReportsScroll: ViewModifier {
    var context: TabsKitContentContext?
    func body(content: Content) -> some View {
        if let context { content.tabsKitReportsScroll(context) } else { content }
    }
}

/// The note's row above the toolbar.
struct NoteAccessory: View {
    var words: Int
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(words == 1 ? "1 word" : "\(words) words").font(.system(size: 15, weight: .medium)).monospacedDigit()
            Spacer(minLength: 0)
            Button("Clear", systemImage: "eraser", action: onClear).labelStyle(.iconOnly)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 34)
    }
}

/// The start page as the web page draws it: Favorites and the page tiles.
struct DemoStartCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites").font(.system(size: 22, weight: .bold)).foregroundStyle(Color(white: 0.07))
            HStack(spacing: 12) {
                ForEach(DemoSite.pages.filter { $0.name != "start" }, id: \.name) { page in
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(red: Double((page.color >> 16) & 0xFF) / 255, green: Double((page.color >> 8) & 0xFF) / 255,
                                    blue: Double(page.color & 0xFF) / 255))
                        .frame(width: 72, height: 72)
                        .overlay(alignment: .bottom) {
                            Text(page.title).font(.system(size: 12)).foregroundStyle(.white).padding(.bottom, 6)
                        }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 62 + 8 + 20 + 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255))
    }
}
