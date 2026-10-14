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

    init() {
        for name in ["springs", "glass", "pinch", "night"] { addWebPage(URL(string: "tabskit://pages/\(name)")!) }
        addNote("Notes are plain SwiftUI tabs.\n\nThey get the same grid, zoom, swipe and toolbar as web pages, with their own card, page menu and an accessory row above the toolbar.")
        activeTabID = order.first
    }

    // MARK: TabsDataSource

    var tabs: [TabsKitTab] { order.compactMap(tab(for:)) }

    func activate(_ id: String) {
        guard id != activeTabID, order.contains(id) else { return }
        if let old = activeTabID { refreshThumbnail(old) }
        activeTabID = id
    }

    func close(_ id: String) {
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index)
        webPages[id] = nil
        notes[id] = nil
        thumbnails[id] = nil
        if activeTabID == id { activeTabID = order.isEmpty ? nil : order[min(index, order.count - 1)] }
    }

    func createTab(_ option: TabsKitNewTabOption) async -> String? {
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
                TabsKitMenuItem(title: "Close Note", systemImage: "xmark.square", isDestructive: true) { [weak self] in self?.close(tab.id) },
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
                TabsKitMenuItem(title: "Close Tab", systemImage: "xmark.square") { [weak self] in self?.close(tab.id) },
            ],
        ]
    }

    // MARK: Model

    @discardableResult
    private func addWebPage(_ url: URL) -> String {
        let id = makeId()
        let page = DemoWebPage(url: url, configuration: configuration)
        page.onLoaded = { [weak self] in self?.refreshThumbnail(id) }
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
