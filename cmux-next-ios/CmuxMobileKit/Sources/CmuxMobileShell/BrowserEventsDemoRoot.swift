#if DEBUG && os(iOS)
import CmuxTabsKit
import CmuxMobileBrowserStream
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
import SwiftUI
import UIKit

/// Synthetic host data, rendered by the production browser and TabsKit controls.
/// Launch with `-cmux-mobile-browser-events empty|context|select|dialog|prompt|page-menu`.
@MainActor
public struct BrowserEventsDemoRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-browser-events")
    }

    @State private var fixture: BrowserEventsDemoFixture
    @State private var showingOverview = false

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let index = arguments.firstIndex(of: "-cmux-mobile-browser-events")
        let scene = index.flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil } ?? "empty"
        _fixture = State(initialValue: BrowserEventsDemoFixture(scene: scene))
    }

    public var body: some View {
        TabsView(source: fixture.source, isShowingOverview: $showingOverview)
            .tabsKitTheme(.mobile)
            .tint(CmuxMobileTheme.standard.colors.label.color)
            .task {
                // Bounded choreography for the capture harness, cancelled with the view.
                do { try await Task.sleep(for: .milliseconds(1_200)) } catch { return }
                guard !Task.isCancelled else { return }
                fixture.prepareCapture()
            }
            .onDisappear { fixture.close() }
    }
}

@MainActor
private final class BrowserEventsDemoFixture {
    let scene: String
    let directory: StreamedBrowserDirectory
    let source: WorkspaceTabsSource
    private var backdrop: UIView?

    init(scene: String) {
        self.scene = scene
        let directory = StreamedBrowserDirectory()
        let transport = BrowserEventsDemoTransport(scene: scene)
        directory.opener = { transport }
        let tab = WorkspaceTab(id: "browser-events-tab", kind: .browser, title: "Project notes",
                               url: URL(string: "https://events.example.test"))
        let workspace = Workspace(id: "browser-events-workspace", macID: "demo", title: "Project notes",
                                  directory: "/tmp/demo", tabs: [tab], lastActivityAt: Date())
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [workspace], feed: [], tabMemory: .inMemory())
        self.directory = directory
        source = WorkspaceTabsSource(store: store, workspaceID: workspace.id, streamed: directory)
    }

    func close() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        directory.reset()
    }

    func prepareCapture() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow),
              let page = findPage(in: window) else {
            print("browser-events-demo: browser.page not found")
            return
        }
        installBackdrop(in: page)
        if scene == "context" {
            presentContextMenu(on: page)
        }
    }

    private func findPage(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "browser.page" { return view }
        for child in view.subviews { if let page = findPage(in: child) { return page } }
        return nil
    }

    /// The only substitute is the page's synthetic content, placed INSIDE the
    /// real stream view. Production dialogs, sheets, menus and chrome draw above it.
    private func installBackdrop(in page: UIView) {
        let background = UIView(frame: page.bounds)
        background.backgroundColor = .systemBackground
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        background.isUserInteractionEnabled = false
        background.accessibilityElementsHidden = true
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (text, style) in [("Project notes", UIFont.TextStyle.largeTitle),
                              ("Research & development", .title2),
                              ("A shared space for ideas and experiments.", .body),
                              ("Team", .headline), ("R&D  ▾", .body),
                              ("Save changes", .headline),
                              ("Review the project before continuing.", .body)] {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: style)
            label.textColor = .label
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
        ])
        page.addSubview(background)
        backdrop = background
    }

    private func presentContextMenu(on page: UIView) {
        guard let interaction = page.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first else {
            // Base has no long-press interaction: the same synthetic page remains visible.
            print("browser-events-demo: no page context interaction")
            return
        }
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: selector), let method = interaction.method(for: selector) else { return }
        // The same DEBUG-only entry point used by DemoDriver's workspace-menu capture.
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(method, to: Present.self)(interaction, selector,
                                              CGPoint(x: page.bounds.midX, y: page.bounds.midY))
    }

}
#endif
