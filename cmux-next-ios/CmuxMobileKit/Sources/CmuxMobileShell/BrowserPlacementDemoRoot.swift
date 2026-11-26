#if DEBUG && os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
import CmuxTabsKit
import SwiftUI
import UIKit

/// Settings → Browser → Open New Pages, end to end on synthetic data: a Mac (the
/// browser-events demo transport) lists a new browser tab, the real rule
/// (`NativeBrowserTabs.listed`, `BrowserPagePlacement`) places it, and the production
/// TabsKit page shows it, on the phone in WebKit or streamed from the Mac.
/// Launch with `-cmux-mobile-browser-placement public|html|signin|localhost|private|blank|macfile|unreadable`
/// and the setting as `-cmuxMobile.settings.browserOpenDefault automatic|phone|stream`.
@MainActor
public struct BrowserPlacementDemoRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-browser-placement")
    }

    @State private var fixture: BrowserPlacementDemoFixture
    @State private var showingOverview = false

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let index = arguments.firstIndex(of: "-cmux-mobile-browser-placement")
        let kind = index.flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil } ?? "html"
        _fixture = State(initialValue: BrowserPlacementDemoFixture(kind: kind))
    }

    public var body: some View {
        TabsView(source: fixture.source, isShowingOverview: $showingOverview)
            .tabsKitTheme(.mobile)
            .tint(CmuxMobileTheme.standard.colors.label.color)
            .overlay(alignment: .top) { caption }
            .task {
                do { try await Task.sleep(for: .milliseconds(1_200)) } catch { return }
                guard !Task.isCancelled else { return }
                fixture.prepareCapture()
            }
            .onDisappear { fixture.close() }
    }

    /// What the rule decided, for the screenshot (the page itself is the proof of where it shows).
    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Open New Pages: \(fixture.preference.title)")
                .font(.caption.weight(.semibold))
            Text("\(fixture.address) → \(fixture.decision.target == .phone ? "On iPhone" : "Streamed from Mac") (\(fixture.decision.reason.rawValue))")
                .font(.caption2.monospaced())
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(fixture.decision.target == .phone ? Color.blue.opacity(0.88) : Color.purple.opacity(0.88), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 54)
        .allowsHitTesting(false)
        .accessibilityIdentifier("browser.placement.caption")
    }
}

@MainActor
private final class BrowserPlacementDemoFixture {
    let kind: String
    let address: String
    let preference: BrowserOpenDefault
    let decision: BrowserPagePlacement
    let directory: StreamedBrowserDirectory
    let native: NativeBrowserTabs
    let source: WorkspaceTabsSource
    private var backdrop: UIView?

    static let addresses: [String: String] = [
        "public": "https://example.com/",
        "html": "file:///Users/aziz/artifacts/browser-open-on-phone/report.html",
        "unreadable": "file:///private/tmp/outside-workspace/report.html",
        "signin": "https://github.com/manaflow-ai/cmux/pulls",
        "localhost": "http://localhost:3000/",
        "private": "http://studio.local:5173/",
        "blank": "about:blank",
        "macfile": "file:///Users/aziz/Desktop/screenshot.png",
    ]

    init(kind: String) {
        let address = Self.addresses[kind] ?? Self.addresses["html"]!
        let preference = BrowserOpenDefault.current()
        let directory = StreamedBrowserDirectory()
        let transport = BrowserEventsDemoTransport(scene: "empty")
        directory.opener = { transport }
        let suite = "browser-placement-demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let native = NativeBrowserTabs(defaults: defaults)
        native.preference = { preference }
        native.seedWindow = .zero
        native.readMacHTML = { url, _ in
            try await Task.sleep(for: .milliseconds(250))
            if url.path().hasPrefix("/private/tmp") {
                throw DemoUnreadable()
            }
            return BrowserPlacementDemoFixture.reportHTML
        }
        let url = URL(string: address)
        let tab = WorkspaceTab(id: "placement-tab", kind: .browser, title: url?.lastPathComponent ?? "New Tab", url: url)
        let workspace = Workspace(id: "placement-workspace", macID: "demo", title: "Agent report",
                                  directory: "/Users/aziz/artifacts", tabs: [tab], lastActivityAt: Date())
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [workspace], feed: [], tabMemory: .inMemory())
        // The Mac's first list had no browser tab; its next list has this new one.
        native.listed(macID: "demo", browserTabs: [])
        native.listed(macID: "demo", browserTabs: [(id: tab.id, url: url)])
        self.kind = kind
        self.address = address
        self.preference = preference
        decision = native.placement(for: url, macID: "demo")
        self.directory = directory
        self.native = native
        source = WorkspaceTabsSource(store: store, workspaceID: workspace.id, native: native, streamed: directory)
    }

    struct DemoUnreadable: LocalizedError {
        var errorDescription: String? { "/private/tmp/outside-workspace isn't inside a workspace folder on this Mac." }
    }

    func close() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        directory.reset()
    }

    /// A streamed page shows the Mac's synthetic page inside the real stream view.
    func prepareCapture() {
        guard decision.target == .stream,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow),
              let page = findPage(in: window) else { return }
        let background = UIView(frame: page.bounds)
        background.backgroundColor = UIColor(white: 0.13, alpha: 1)
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        background.isUserInteractionEnabled = false
        background.accessibilityElementsHidden = true
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (text, style) in [("Streaming from the Mac", UIFont.TextStyle.title2),
                              ("The Mac's own browser, signed in as on the Mac.", .body),
                              (address, .footnote)] {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: style)
            label.textColor = .white
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 150),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
        ])
        page.addSubview(background)
        backdrop = background
    }

    private func findPage(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "browser.page" { return view }
        for child in view.subviews { if let page = findPage(in: child) { return page } }
        return nil
    }

    static let reportHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Browser open-on-phone report</title>
    <style>
    body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:150px 20px 40px;background:#f6f7f9;color:#111}
    @media (prefers-color-scheme:dark){body{background:#111;color:#eee}.card{background:#1c1c1e!important}}
    h1{font-size:26px;margin:0 0 6px} p{color:#666;margin:0 0 16px}
    .card{background:#fff;border-radius:14px;padding:14px 16px;margin:10px 0;box-shadow:0 1px 3px rgba(0,0,0,.08)}
    .ok{color:#1a7f37;font-weight:600}
    </style></head><body>
    <h1>Agent report</h1><p>report.html, read from the Mac over the link and shown in this iPhone's WebKit.</p>
    <div class="card"><b>Fleet build</b><br><span class="ok">passed</span> · 4 min 12 s</div>
    <div class="card"><b>Tests</b><br><span class="ok">38 of 38 passed</span></div>
    <div class="card"><b>Screenshots</b><br>24 permutations captured</div>
    </body></html>
    """
}
#endif
