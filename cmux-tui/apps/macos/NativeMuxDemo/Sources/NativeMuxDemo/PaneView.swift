import SwiftUI

private func localizedContentKind(_ kind: String) -> String {
    kind == "browser"
        ? L10n.text("content.browser", "Browser")
        : L10n.text("content.terminal", "Terminal")
}

struct PaneView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let paneID: String

    private var pane: PaneSnapshot? { snapshot.pane(paneID) }
    private var tabs: [TabSnapshot] { snapshot.tabs(in: paneID) }
    private var activeTab: TabSnapshot? {
        tabs.first { $0.focused } ?? tabs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VerticalTabsView(
                model: model,
                snapshot: snapshot,
                paneID: paneID,
                tabs: tabs,
                activeTab: activeTab
            )
            Divider()
            VStack(spacing: 0) {
                paneHeader
                Divider()
                tabContent
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    pane?.focused == true ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 7) {
            Button {
                model.focusPane(paneID)
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(pane?.focused == true ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(pane?.name ?? activeTabTitle)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            paneButton("rectangle.split.1x2", "pane.split_right") {
                model.splitPane(paneID, direction: "right")
            }
            paneButton("rectangle.split.2x1", "pane.split_down") {
                model.splitPane(paneID, direction: "down")
            }
            paneButton("rectangle.3.group", "pane.new_column") {
                model.createNiriColumn(after: paneID)
            }
            paneButton(pane?.zoomed == true ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", pane?.zoomed == true ? "pane.unzoom" : "pane.zoom") {
                model.zoomPane(paneID, enabled: pane?.zoomed != true)
            }
            Menu {
                Button(L10n.text("pane.new_terminal", "New terminal tab")) {
                    model.createTerminalTab(in: paneID)
                }
                Button(L10n.text("pane.new_browser", "New browser tab")) {
                    model.createBrowserTab(in: paneID)
                }
                Divider()
                Button(L10n.text("pane.close", "Close pane"), role: .destructive) {
                    model.closePane(paneID)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 29)
        .background(.bar)
    }

    private func paneButton(
        _ systemImage: String,
        _ localizationKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .help(helpText(localizationKey))
    }

    private func helpText(_ key: String) -> String {
        switch key {
        case "pane.split_right": return L10n.text(key, "Split right")
        case "pane.split_down": return L10n.text(key, "Split down")
        case "pane.new_column": return L10n.text(key, "New niri column")
        case "pane.unzoom": return L10n.text(key, "Unzoom pane")
        default: return L10n.text(key, "Zoom pane")
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if let activeTab, activeTab.contentKind == "terminal",
            let terminal = snapshot.terminal(for: activeTab),
            let controller = model.terminalController(for: terminal)
        {
            TerminalSurfaceView(terminal: controller)
                .id(terminal.id)
        } else if let activeTab, activeTab.contentKind == "browser",
            let browser = snapshot.browser(for: activeTab)
        {
            BrowserSurfaceView(browser: browser)
                .id(browser.id)
        } else {
            ContentUnavailableView(
                L10n.text("layout.empty", "This space has no panes."),
                systemImage: "rectangle.dashed"
            )
        }
    }

    private var activeTabTitle: String {
        guard let activeTab else {
            return L10n.format("pane.short_id", "Pane %@", String(paneID.suffix(5)))
        }
        if let name = activeTab.name, !name.isEmpty { return name }
        if let terminal = snapshot.terminal(for: activeTab), !terminal.title.isEmpty {
            return terminal.title
        }
        if let browser = snapshot.browser(for: activeTab), !browser.title.isEmpty {
            return browser.title
        }
        return localizedContentKind(activeTab.contentKind)
    }
}

struct VerticalTabsView: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot
    let paneID: String
    let tabs: [TabSnapshot]
    let activeTab: TabSnapshot?

    var body: some View {
        VStack(spacing: 5) {
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.top, 6)
            }
            Menu {
                Button(L10n.text("pane.new_terminal", "New terminal tab")) {
                    model.createTerminalTab(in: paneID)
                }
                Button(L10n.text("pane.new_browser", "New browser tab")) {
                    model.createBrowserTab(in: paneID)
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 24)
            }
            .menuStyle(.borderlessButton)
            .padding(.bottom, 5)
        }
        .frame(width: 42)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private func tabButton(_ tab: TabSnapshot) -> some View {
        let selected = tab.id == activeTab?.id
        return Button {
            model.focusTab(tab)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: tab.contentKind == "browser" ? "globe" : "terminal")
                    .frame(width: 29, height: 29)
                    .background(
                        selected ? Color.accentColor.opacity(0.2) : Color.clear,
                        in: .rect(cornerRadius: 6)
                    )
                Text("\(tab.index + 1)")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .help(tab.name ?? localizedContentKind(tab.contentKind))
        .contextMenu {
            Button(L10n.text("tab.close", "Close tab"), role: .destructive) {
                model.closeTab(tab)
            }
        }
    }

}
