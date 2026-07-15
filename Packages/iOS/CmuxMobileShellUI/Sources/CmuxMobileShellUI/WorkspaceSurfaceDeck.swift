import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceSurfaceDeckActions {
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let createTerminal: (MobileWorkspacePanePreview.ID?) -> Void
    let showOverview: () -> Void
}

/// Persistent pane and tab navigation above the active full-screen surface.
struct WorkspaceSurfaceDeck: View {
    let value: WorkspaceSurfaceDeckValue
    let terminalTheme: TerminalTheme
    let actions: WorkspaceSurfaceDeckActions
    @ScaledMetric(relativeTo: .caption) private var paneRowHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .caption) private var tabRowHeight: CGFloat = 34

    private var resolvedPaneRowHeight: CGFloat { min(paneRowHeight, 50) }
    private var resolvedTabRowHeight: CGFloat { min(tabRowHeight, 46) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 7) {
                            ForEach(value.panes) { pane in
                                paneButton(pane)
                                    .id(pane.id)
                            }
                        }
                    }
                    .frame(height: resolvedPaneRowHeight)
                    .scrollIndicators(.hidden)
                    .onAppear {
                        scrollToActivePane(using: proxy, animated: false)
                    }
                    .onChange(of: value.activePaneID) { _, _ in
                        scrollToActivePane(using: proxy, animated: true)
                    }
                }

                Button(action: actions.showOverview) {
                    Image(systemName: value.panes.count > 1 ? "square.grid.2x2" : "rectangle.inset.filled")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: resolvedPaneRowHeight, height: resolvedPaneRowHeight)
                        .background(chromeForeground.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(chromeForeground)
                .accessibilityLabel(L10n.string("mobile.surfaceDeck.overview", defaultValue: "Pane Overview"))
                .accessibilityValue(value.activePane?.selectedTerminal?.name ?? "")
                .accessibilityIdentifier("MobilePaneOverviewButton")
            }

            if let activePane = value.activePane {
                HStack(spacing: 7) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 6) {
                                ForEach(activePane.terminals) { terminal in
                                    tabButton(terminal, in: activePane)
                                        .id(terminal.id)
                                }
                            }
                        }
                        .frame(height: resolvedTabRowHeight)
                        .scrollIndicators(.hidden)
                        .onAppear {
                            scrollToSelectedTab(using: proxy, animated: false)
                        }
                        .onChange(of: value.selectedTerminalID) { _, _ in
                            scrollToSelectedTab(using: proxy, animated: true)
                        }
                    }

                    Button {
                        actions.createTerminal(activePane.remoteID)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: resolvedTabRowHeight, height: resolvedTabRowHeight)
                            .background(Color.accentColor.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"))
                    .accessibilityIdentifier("MobilePaneNewTerminalButton-\(activePane.id.rawValue)")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background {
            ZStack {
                terminalTheme.terminalBackgroundColor.opacity(0.96)
                Rectangle().fill(.ultraThinMaterial).opacity(0.34)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(chromeForeground.opacity(0.12))
                .frame(height: 0.5)
        }
        .environment(\.colorScheme, terminalTheme.terminalColorScheme)
    }

    private func scrollToActivePane(using proxy: ScrollViewProxy, animated: Bool) {
        guard let paneID = value.activePaneID else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(paneID, anchor: .center)
            }
        } else {
            proxy.scrollTo(paneID, anchor: .center)
        }
    }

    private func scrollToSelectedTab(using proxy: ScrollViewProxy, animated: Bool) {
        guard let terminalID = value.selectedTerminalID else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(terminalID, anchor: .center)
            }
        } else {
            proxy.scrollTo(terminalID, anchor: .center)
        }
    }

    private func paneButton(_ pane: WorkspaceSurfaceDeckValue.Pane) -> some View {
        let isActive = pane.id == value.activePaneID
        return Button {
            if let terminalID = pane.selectedTerminal?.id {
                actions.selectTerminal(terminalID)
            }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isActive ? Color.accentColor : dimChromeForeground, lineWidth: 1.3)
                        .frame(width: 20, height: 17)
                    Text("\(pane.index)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.paneName(index: pane.index))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isActive ? Color.accentColor : dimChromeForeground)
                    Text(
                        pane.selectedTerminal?.name
                            ?? L10n.string("mobile.surfaceDeck.emptyPane", defaultValue: "No Terminal")
                    )
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(chromeForeground)
                }
                Text("\(pane.terminals.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isActive ? Color.accentColor : dimChromeForeground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(chromeForeground.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 9)
            .frame(height: resolvedPaneRowHeight)
            .background(
                isActive ? Color.accentColor.opacity(0.17) : chromeForeground.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.72) : chromeForeground.opacity(0.11),
                        lineWidth: isActive ? 1 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(pane.selectedTerminal == nil)
        .accessibilityLabel(L10n.paneAccessibilityLabel(index: pane.index, terminalCount: pane.terminals.count))
        .accessibilityValue(pane.selectedTerminal?.name ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("MobilePaneButton-\(pane.id.rawValue)")
    }

    private func tabButton(
        _ terminal: MobileTerminalPreview,
        in pane: WorkspaceSurfaceDeckValue.Pane
    ) -> some View {
        let isSelected = terminal.id == value.selectedTerminalID
        return Button {
            actions.selectTerminal(terminal.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "terminal.fill" : "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Text(terminal.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: resolvedTabRowHeight)
            .foregroundStyle(isSelected ? Color.accentColor : chromeForeground)
            .background(
                isSelected ? Color.accentColor.opacity(0.17) : chromeForeground.opacity(0.055),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.68) : chromeForeground.opacity(0.1),
                    lineWidth: isSelected ? 1 : 0.5
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(terminal.name)
        .accessibilityHint(L10n.string("mobile.surfaceDeck.selectTabHint", defaultValue: "Shows this terminal tab"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("MobileSurfaceTab-\(pane.id.rawValue)-\(terminal.id.rawValue)")
    }

    private var chromeForeground: Color {
        terminalTheme.terminalChromeForegroundColor
    }

    private var dimChromeForeground: Color {
        chromeForeground.opacity(0.78)
    }
}
