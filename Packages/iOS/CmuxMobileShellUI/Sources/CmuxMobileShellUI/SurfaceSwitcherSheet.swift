import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

struct SurfaceSwitcherSheet: View {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    let terminalTheme: TerminalTheme
    let dismiss: () -> Void

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SurfaceSwitcherHeader(
                title: L10n.string("mobile.surfaceSwitcher.title", defaultValue: "Switch Tab"),
                subtitle: subtitle,
                foreground: foreground,
                dismiss: dismiss
            )
            if value.shouldShowSearch {
                SurfaceSwitcherSearchField(
                    searchText: $searchText,
                    foreground: foreground
                )
                .focused($searchFocused)
                .padding(.horizontal, SurfaceSwitcherMetrics.sideInset)
                .padding(.bottom, 10)
            }
            SurfaceSwitcherDestinationList(
                destinations: visibleDestinations,
                activeDestinationID: value.activeDestinationID,
                supportsBrowserStream: value.supportsBrowserStream,
                browserRefreshState: value.browserRefreshState,
                hasBrowserRows: !value.browserStreamRows.isEmpty,
                searchText: searchText,
                foreground: foreground,
                select: select,
                retryBrowserStreamRefresh: actions.retryBrowserStreamRefresh
            )
            SurfaceSwitcherFooter(
                foreground: foreground,
                createTerminal: {
                    actions.createTerminal()
                    dismiss()
                },
                openBrowser: {
                    actions.openBrowser()
                    dismiss()
                }
            )
        }
        .background(terminalTheme.terminalBackgroundColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileSurfaceSwitcher")
    }

    private var foreground: Color {
        terminalTheme.terminalChromeForegroundColor
    }

    private var visibleDestinations: [SurfaceSwitcherDestination] {
        value.filteredDestinations(searchText: searchText)
    }

    private var subtitle: String {
        let count = value.destinations.count
        if count == 1 {
            return L10n.string("mobile.switchTab.destinationCount.one", defaultValue: "1 tab")
        }
        return String(
            format: L10n.string("mobile.switchTab.destinationCount.other", defaultValue: "%d tabs"),
            count
        )
    }

    private func select(_ destination: SurfaceSwitcherDestination) {
        switch destination.kind {
        case .terminal(let terminalID):
            actions.selectTerminal(terminalID)
        case .chat(let sessionID):
            actions.openChat(sessionID)
        case .localBrowser:
            actions.openLocalBrowser()
        case .browserStream(let panelID):
            actions.selectBrowserStream(panelID)
        }
        dismiss()
    }
}

private struct SurfaceSwitcherHeader: View {
    let title: String
    let subtitle: String
    let foreground: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(foreground.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(foreground)
            .accessibilityLabel(L10n.string("mobile.common.done", defaultValue: "Done"))
            .accessibilityIdentifier("MobileSurfaceSwitcherCloseButton")
        }
        .padding(.horizontal, SurfaceSwitcherMetrics.sideInset)
        .padding(.top, SurfaceSwitcherMetrics.headerTopInset)
        .padding(.bottom, 12)
    }
}

private struct SurfaceSwitcherSearchField: View {
    @Binding var searchText: String
    let foreground: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(foreground.opacity(0.62))
            TextField(
                L10n.string("mobile.switchTab.search", defaultValue: "Search tabs"),
                text: $searchText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .foregroundStyle(foreground)
            .frame(minHeight: 44)
            .accessibilityIdentifier("MobileSurfaceSwitcherSearchField")
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foreground.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct SurfaceSwitcherDestinationList: View {
    let destinations: [SurfaceSwitcherDestination]
    let activeDestinationID: SurfaceSwitcherDestination.ID?
    let supportsBrowserStream: Bool
    let browserRefreshState: SurfaceSwitcherBrowserRefreshState
    let hasBrowserRows: Bool
    let searchText: String
    let foreground: Color
    let select: (SurfaceSwitcherDestination) -> Void
    let retryBrowserStreamRefresh: () -> Void
    @State private var scrollPosition: ScrollPosition

    init(
        destinations: [SurfaceSwitcherDestination],
        activeDestinationID: SurfaceSwitcherDestination.ID?,
        supportsBrowserStream: Bool,
        browserRefreshState: SurfaceSwitcherBrowserRefreshState,
        hasBrowserRows: Bool,
        searchText: String,
        foreground: Color,
        select: @escaping (SurfaceSwitcherDestination) -> Void,
        retryBrowserStreamRefresh: @escaping () -> Void
    ) {
        self.destinations = destinations
        self.activeDestinationID = activeDestinationID
        self.supportsBrowserStream = supportsBrowserStream
        self.browserRefreshState = browserRefreshState
        self.hasBrowserRows = hasBrowserRows
        self.searchText = searchText
        self.foreground = foreground
        self.select = select
        self.retryBrowserStreamRefresh = retryBrowserStreamRefresh
        let destinationID = Self.visibleActiveDestinationID(
            destinations: destinations,
            activeDestinationID: activeDestinationID
        )
        _scrollPosition = State(initialValue: destinationID.map {
            ScrollPosition(id: $0, anchor: .center)
        } ?? ScrollPosition(idType: SurfaceSwitcherDestination.ID.self))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SurfaceSwitcherMetrics.rowSpacing) {
                ForEach(listItems) { item in
                    switch item.content {
                    case .header(let title, let topPadding):
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(foreground.opacity(0.62))
                            .padding(.horizontal, 2)
                            .padding(.top, topPadding)
                    case .destination(let destination):
                        SurfaceSwitcherDestinationRow(
                            destination: destination,
                            isSelected: destination.id == activeDestinationID,
                            foreground: foreground,
                            select: select
                        )
                        .id(destination.id)
                    case .status(let status):
                        status
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, SurfaceSwitcherMetrics.sideInset)
            .padding(.top, 2)
            .padding(.bottom, SurfaceSwitcherMetrics.contentBottomInset)
        }
        .scrollPosition($scrollPosition)
        .accessibilityIdentifier("MobileSurfaceSwitcherList")
        .onChange(of: visibleActiveDestinationID) { _, destinationID in
            guard let destinationID else { return }
            scrollPosition.scrollTo(id: destinationID, anchor: .center)
        }
    }

    private var listItems: [SurfaceSwitcherListItem] {
        if destinations.isEmpty, !searchText.isEmpty {
            return [
                .status(
                    SurfaceSwitcherStatusRow(
                        title: L10n.string("mobile.switchTab.noResults", defaultValue: "No matching tabs"),
                        subtitle: L10n.string("mobile.switchTab.noResultsDetail", defaultValue: "Try a different title or source."),
                        systemImage: "magnifyingglass",
                        foreground: foreground,
                        accessibilityIdentifier: "MobileSurfaceSwitcherNoResults"
                    )
                )
            ]
        }

        var items: [SurfaceSwitcherListItem] = []
        items += sectionItems(
            id: "terminals",
            title: L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"),
            rows: destinations.filter(\.kind.isTerminal),
            empty: searchText.isEmpty ? terminalEmptyRow : nil,
            isFirst: items.isEmpty
        )
        items += sectionItems(
            id: "agent-chat",
            title: L10n.string("mobile.switchTab.agentChat", defaultValue: "Agent Chat"),
            rows: destinations.filter(\.kind.isChat),
            empty: nil,
            isFirst: items.isEmpty
        )
        items += sectionItems(
            id: "browsers",
            title: L10n.string("mobile.browserStream.menuTitle", defaultValue: "Browsers"),
            rows: destinations.filter(\.kind.isBrowser),
            empty: searchText.isEmpty ? browserStatusRow : nil,
            isFirst: items.isEmpty
        )
        return items
    }

    private func sectionItems(
        id: String,
        title: String,
        rows: [SurfaceSwitcherDestination],
        empty: SurfaceSwitcherStatusRow?,
        isFirst: Bool
    ) -> [SurfaceSwitcherListItem] {
        guard !rows.isEmpty || empty != nil else { return [] }
        var items: [SurfaceSwitcherListItem] = [
            .header(
                id: id,
                title: title,
                topPadding: isFirst ? 0 : SurfaceSwitcherMetrics.sectionSpacing - SurfaceSwitcherMetrics.rowSpacing
            )
        ]
        if rows.isEmpty, let empty {
            items.append(.status(empty))
        } else {
            items += rows.map(SurfaceSwitcherListItem.destination)
        }
        return items
    }

    private var terminalEmptyRow: SurfaceSwitcherStatusRow? {
        SurfaceSwitcherStatusRow(
            title: L10n.string("mobile.surfaceSwitcher.noTerminals", defaultValue: "No terminals in this workspace"),
            subtitle: L10n.string("mobile.switchTab.noTerminalsDetail", defaultValue: "Create a terminal from the footer."),
            systemImage: "terminal",
            foreground: foreground,
            accessibilityIdentifier: "MobileSurfaceSwitcherNoTerminals"
        )
    }

    private var browserStatusRow: SurfaceSwitcherStatusRow? {
        if !supportsBrowserStream {
            return SurfaceSwitcherStatusRow(
                title: L10n.string("mobile.macUpdateHint.browserStream", defaultValue: "Update cmux on your Mac to stream browser panes"),
                subtitle: L10n.string("mobile.switchTab.unsupportedBrowserDetail", defaultValue: "Mac browser tabs appear here after the Mac app is updated."),
                systemImage: "arrow.down.circle",
                foreground: foreground,
                accessibilityIdentifier: "BrowserStreamMacUpdateHint"
            )
        }
        switch browserRefreshState {
        case .loading:
            return SurfaceSwitcherStatusRow(
                title: L10n.string("mobile.switchTab.loadingBrowsers", defaultValue: "Loading Mac browsers"),
                subtitle: L10n.string("mobile.switchTab.loadingBrowsersDetail", defaultValue: "Checking the paired Mac."),
                systemImage: "arrow.triangle.2.circlepath",
                foreground: foreground,
                accessibilityIdentifier: "BrowserStreamLoadingState"
            )
        case .failed:
            return SurfaceSwitcherStatusRow(
                title: L10n.string("mobile.switchTab.browserFailure", defaultValue: "Could not load Mac browsers"),
                subtitle: L10n.string("mobile.switchTab.browserFailureDetail", defaultValue: "Check the Mac connection and try again."),
                systemImage: "exclamationmark.triangle",
                foreground: foreground,
                accessibilityIdentifier: "BrowserStreamFailureState",
                retry: retryBrowserStreamRefresh
            )
        case .idle:
            guard !hasBrowserRows else { return nil }
            return SurfaceSwitcherStatusRow(
                title: L10n.string("mobile.browserStream.empty", defaultValue: "No Mac browser streams"),
                subtitle: L10n.string("mobile.switchTab.noMacBrowsersDetail", defaultValue: "Open a browser pane on the Mac to stream it here."),
                systemImage: "display",
                foreground: foreground,
                accessibilityIdentifier: "BrowserStreamEmptyState"
            )
        }
    }

    private var visibleActiveDestinationID: SurfaceSwitcherDestination.ID? {
        Self.visibleActiveDestinationID(
            destinations: destinations,
            activeDestinationID: activeDestinationID
        )
    }

    private static func visibleActiveDestinationID(
        destinations: [SurfaceSwitcherDestination],
        activeDestinationID: SurfaceSwitcherDestination.ID?
    ) -> SurfaceSwitcherDestination.ID? {
        guard let activeDestinationID,
              destinations.contains(where: { $0.id == activeDestinationID }) else { return nil }
        return activeDestinationID
    }
}

private struct SurfaceSwitcherListItem: Identifiable {
    enum Content {
        case header(title: String, topPadding: CGFloat)
        case destination(SurfaceSwitcherDestination)
        case status(SurfaceSwitcherStatusRow)
    }

    let id: String
    let content: Content

    static func header(id: String, title: String, topPadding: CGFloat) -> Self {
        Self(id: "header:\(id)", content: .header(title: title, topPadding: topPadding))
    }

    static func destination(_ destination: SurfaceSwitcherDestination) -> Self {
        Self(id: destination.id, content: .destination(destination))
    }

    static func status(_ status: SurfaceSwitcherStatusRow) -> Self {
        Self(id: "status:\(status.accessibilityIdentifier)", content: .status(status))
    }
}

private struct SurfaceSwitcherDestinationRow: View {
    let destination: SurfaceSwitcherDestination
    let isSelected: Bool
    let foreground: Color
    let select: (SurfaceSwitcherDestination) -> Void

    var body: some View {
        Button {
            select(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: destination.systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: SurfaceSwitcherMetrics.iconWell, height: SurfaceSwitcherMetrics.iconWell)
                    .background(
                        foreground.opacity(isSelected ? 0.18 : 0.10),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(destination.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(foreground.opacity(0.68))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(foreground)
                        .frame(width: SurfaceSwitcherMetrics.checkWell, height: SurfaceSwitcherMetrics.checkWell)
                        .accessibilityHidden(true)
                } else {
                    Color.clear
                        .frame(width: SurfaceSwitcherMetrics.checkWell, height: SurfaceSwitcherMetrics.checkWell)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SurfaceSwitcherMetrics.rowHorizontalPadding)
            .padding(.vertical, 10)
            .frame(minHeight: SurfaceSwitcherMetrics.rowMinHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(foreground.opacity(isSelected ? 0.18 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(foreground.opacity(isSelected ? 0.50 : 0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.string("mobile.switchTab.row.accessibilityLabel", defaultValue: "%1$@, %2$@"),
                destination.title,
                destination.subtitle
            )
        )
        .accessibilityValue(isSelected ? L10n.string("mobile.surfaceSwitcher.selected", defaultValue: "Selected") : "")
        .accessibilityIdentifier(destination.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SurfaceSwitcherStatusRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let foreground: Color
    let accessibilityIdentifier: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: SurfaceSwitcherMetrics.iconWell, height: SurfaceSwitcherMetrics.iconWell)
                    .background(foreground.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(foreground)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(foreground.opacity(0.68))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle)
            .accessibilityIdentifier(accessibilityIdentifier)
            if let retry {
                Button(action: retry) {
                    Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserStreamRetryButton")
            }
        }
        .padding(.horizontal, SurfaceSwitcherMetrics.rowHorizontalPadding)
        .padding(.vertical, 10)
        .frame(minHeight: SurfaceSwitcherMetrics.rowMinHeight)
        .background(foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foreground.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct SurfaceSwitcherFooter: View {
    let foreground: Color
    let createTerminal: () -> Void
    let openBrowser: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Divider().overlay(foreground.opacity(0.18))
            HStack(spacing: 10) {
                footerButton(
                    title: L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                    systemImage: "plus",
                    accessibilityIdentifier: "MobileNewTerminalMenuItem",
                    action: createTerminal
                )
                footerButton(
                    title: L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                    systemImage: "globe",
                    accessibilityIdentifier: "MobileNewBrowserMenuItem",
                    action: openBrowser
                )
            }
            .padding(.horizontal, SurfaceSwitcherMetrics.sideInset)
            .padding(.bottom, SurfaceSwitcherMetrics.footerBottomInset)
        }
        .background(.bar)
    }

    private func footerButton(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(foreground.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foreground.opacity(0.16), lineWidth: 1)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum SurfaceSwitcherMetrics {
    static let regularPopoverWidth: CGFloat = 420
    static let regularPopoverMaxHeight: CGFloat = 620
    static let sideInset: CGFloat = 20
    static let headerTopInset: CGFloat = 18
    static let contentBottomInset: CGFloat = 18
    static let footerBottomInset: CGFloat = 14
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 8
    static let rowMinHeight: CGFloat = 60
    static let rowHorizontalPadding: CGFloat = 16
    static let iconWell: CGFloat = 34
    static let checkWell: CGFloat = 24
}

private extension SurfaceSwitcherDestination.Kind {
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    var isChat: Bool {
        if case .chat = self { return true }
        return false
    }

    var isBrowser: Bool {
        switch self {
        case .localBrowser, .browserStream:
            return true
        case .terminal, .chat:
            return false
        }
    }
}
