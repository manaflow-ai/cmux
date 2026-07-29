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
    @State private var lastAutoScrolledDestinationID: SurfaceSwitcherDestination.ID?
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
                lastAutoScrolledDestinationID: $lastAutoScrolledDestinationID,
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
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foreground.opacity(0.14), lineWidth: 1)
        }
        .accessibilityIdentifier("MobileSurfaceSwitcherSearchField")
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
    @Binding var lastAutoScrolledDestinationID: SurfaceSwitcherDestination.ID?
    let select: (SurfaceSwitcherDestination) -> Void
    let retryBrowserStreamRefresh: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SurfaceSwitcherMetrics.sectionSpacing) {
                    if destinations.isEmpty, !searchText.isEmpty {
                        SurfaceSwitcherStatusRow(
                            title: L10n.string("mobile.switchTab.noResults", defaultValue: "No matching tabs"),
                            subtitle: L10n.string("mobile.switchTab.noResultsDetail", defaultValue: "Try a different title or source."),
                            systemImage: "magnifyingglass",
                            foreground: foreground,
                            accessibilityIdentifier: "MobileSurfaceSwitcherNoResults"
                        )
                    } else {
                        section(
                            title: L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"),
                            rows: destinations.filter(\.kind.isTerminal),
                            empty: terminalEmptyRow
                        )
                        section(
                            title: L10n.string("mobile.switchTab.agentChat", defaultValue: "Agent Chat"),
                            rows: destinations.filter(\.kind.isChat),
                            empty: nil
                        )
                        section(
                            title: L10n.string("mobile.browserStream.menuTitle", defaultValue: "Browsers"),
                            rows: destinations.filter(\.kind.isBrowser),
                            empty: browserStatusRow
                        )
                    }
                }
                .padding(.horizontal, SurfaceSwitcherMetrics.sideInset)
                .padding(.top, 2)
                .padding(.bottom, SurfaceSwitcherMetrics.contentBottomInset)
            }
            .accessibilityIdentifier("MobileSurfaceSwitcherList")
            .onAppear { scheduleAutoScroll(proxy) }
            .onChange(of: activeDestinationID) { _, _ in
                scheduleAutoScroll(proxy)
            }
        }
    }

    @ViewBuilder
    private func section(
        title: String,
        rows: [SurfaceSwitcherDestination],
        empty: SurfaceSwitcherStatusRow?
    ) -> some View {
        if !rows.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(foreground.opacity(0.62))
                    .padding(.horizontal, 2)
                LazyVStack(spacing: SurfaceSwitcherMetrics.rowSpacing) {
                    if rows.isEmpty, let empty {
                        empty
                    } else {
                        ForEach(rows) { destination in
                            SurfaceSwitcherDestinationRow(
                                destination: destination,
                                isSelected: destination.id == activeDestinationID,
                                foreground: foreground,
                                select: select
                            )
                            .id(destination.id)
                        }
                    }
                }
            }
        }
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

    private func scheduleAutoScroll(_ proxy: ScrollViewProxy) {
        guard let destinationID = activeDestinationID else {
            lastAutoScrolledDestinationID = nil
            return
        }
        guard lastAutoScrolledDestinationID != destinationID else { return }
        Task { @MainActor in
            await Task.yield()
            guard activeDestinationID == destinationID,
                  lastAutoScrolledDestinationID != destinationID else { return }
            withAnimation(.snappy(duration: 0.2)) {
                proxy.scrollTo(destinationID, anchor: .center)
            }
            lastAutoScrolledDestinationID = destinationID
        }
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(foreground)
                    .frame(width: SurfaceSwitcherMetrics.checkWell, height: SurfaceSwitcherMetrics.checkWell)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
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
        .accessibilityIdentifier(destination.accessibilityIdentifier)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: L10n.string("mobile.switchTab.row.accessibilityLabel", defaultValue: "%1$@, %2$@"),
                destination.title,
                destination.subtitle
            )
        )
        .accessibilityValue(isSelected ? L10n.string("mobile.surfaceSwitcher.selected", defaultValue: "Selected") : "")
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
        .accessibilityIdentifier(accessibilityIdentifier)
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
