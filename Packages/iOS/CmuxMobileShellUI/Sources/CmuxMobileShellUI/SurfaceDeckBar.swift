import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Snapshot-isolated bottom bar for switching among a workspace's panes and surface tabs.
struct SurfaceDeckBar: View, Equatable {
    let value: SurfaceDeckValue
    let actions: SurfaceDeckActions
    let terminalTheme: TerminalTheme
    var clock: any Clock<Duration> = ContinuousClock()

    @State private var unavailableHintID: UUID?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value && lhs.terminalTheme == rhs.terminalTheme
    }

    var body: some View {
        VStack(spacing: 4) {
            if let unavailableHintID {
                Text(
                    L10n.string(
                        "mobile.surfaceDeck.terminalsOnly",
                        defaultValue: "Terminals only on iPhone for now"
                    )
                )
                .font(.caption)
                .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .mobileGlassPill()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: unavailableHintID) {
                    // This is an intended, bounded auto-dismiss. The task is
                    // cancelled when the hint changes or the deck leaves view.
                    try? await clock.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        self.unavailableHintID = nil
                    }
                }
            }

            deckSurface
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
        // The deck is terminal chrome: it extends the terminal's themed
        // background under the glass pills (and into the home-indicator
        // region), so the light theme foreground stays readable instead of
        // landing on the system background.
        .background(
            terminalTheme.terminalBackgroundColor
                .ignoresSafeArea(edges: .bottom)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("mobile.surfaceDeck.label", defaultValue: "Workspace surfaces"))
        .accessibilityIdentifier("MobileSurfaceDeck")
    }

    // No shared GlassEffectContainer here: it composites the pills' glass
    // above the scroll view's clip, so scrolled-away chips bleed under the
    // fixed trailing controls. Each pill/circle carries its own glass.
    private var deckSurface: some View {
        deckContent
    }

    private var deckContent: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(value.groups) { group in
                            paneGroup(group)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    scrollToSelection(using: proxy, animated: false)
                }
                .onChange(of: value.selectedSurfaceID) { _, _ in
                    scrollToSelection(using: proxy, animated: true)
                }
            }

            fixedControls
        }
        .frame(height: 36)
    }

    private func paneGroup(_ group: SurfaceDeckValue.PaneGroup) -> some View {
        HStack(spacing: 2) {
            Text(group.number, format: .number)
                .font(.caption2.weight(.bold))
                .foregroundStyle(terminalTheme.terminalChromeForegroundColor.opacity(0.8))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(terminalTheme.terminalChromeForegroundColor.opacity(0.10))
                )
                .accessibilityLabel(
                    paneAccessibilityLabel(number: group.number, totalCount: group.totalCount)
                )
                .accessibilityIdentifier("MobileSurfaceDeckPaneNumber-\(group.id)")

            ForEach(group.chips) { chip in
                surfaceChip(chip, paneNumber: group.number, paneCount: group.totalCount)
            }
        }
        .padding(2)
        .frame(height: 36)
        .mobileGlassPill()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            paneAccessibilityLabel(number: group.number, totalCount: group.totalCount)
        )
        .accessibilityIdentifier("MobileSurfaceDeckPane-\(group.id)")
    }

    private func surfaceChip(
        _ chip: SurfaceDeckValue.Chip,
        paneNumber: Int,
        paneCount: Int
    ) -> some View {
        let isSelected = chip.id == value.selectedSurfaceID
        let statusKind = value.agentStateKindsBySurfaceID[chip.id]
        return Button {
            if chip.isTerminal {
                actions.selectTerminal(MobileTerminalPreview.ID(rawValue: chip.id))
            } else {
                withAnimation(.snappy(duration: 0.2)) {
                    unavailableHintID = UUID()
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let statusKind {
                    Circle()
                        .fill(statusColor(statusKind))
                        .frame(width: 6, height: 6)
                }

                Image(systemName: systemImage(for: chip.type))
                    .font(.caption.weight(.medium))

                Text(chip.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }
            .foregroundStyle(
                isSelected
                    ? terminalTheme.terminalChromeForegroundColor
                    : terminalTheme.terminalChromeForegroundColor.opacity(0.72)
            )
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background {
                if isSelected {
                    Capsule().fill(terminalTheme.terminalChromeForegroundColor.opacity(0.16))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(chip.isTerminal ? 1 : 0.5)
        .id(chip.id)
        .accessibilityLabel(
            chipAccessibilityLabel(
                chip,
                paneNumber: paneNumber,
                paneCount: paneCount
            )
        )
        .accessibilityValue(statusAccessibilityValue(statusKind))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("MobileSurfaceDeckChip-\(chip.id)")
    }

    private var fixedControls: some View {
        HStack(spacing: 8) {
            if value.showsPaneMap {
                Button(action: actions.presentPaneMap) {
                    Image(systemName: "rectangle.split.2x2")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                        .frame(width: 32, height: 32)
                        .mobileGlassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("mobile.surfaceDeck.paneMap", defaultValue: "Pane Map"))
                .accessibilityIdentifier("MobileSurfaceDeckPaneMap")
            }

            Menu {
                Button(action: actions.createTerminal) {
                    Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                }
                .accessibilityIdentifier("MobileNewTerminalMenuItem")

                Button(action: actions.openBrowser) {
                    Label(L10n.string("mobile.browser.new", defaultValue: "New Browser"), systemImage: "globe")
                }
                .accessibilityIdentifier("MobileNewBrowserMenuItem")

                Button(action: actions.createWorkspace) {
                    Label(
                        L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                        systemImage: "plus.square.on.square"
                    )
                }
                .disabled(!value.canCreateWorkspace)
                .accessibilityIdentifier("MobileNewWorkspaceMenuItem")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                    .frame(width: 32, height: 32)
                    .mobileGlassCircle()
            }
            .accessibilityLabel(L10n.string("mobile.surfaceDeck.add", defaultValue: "Add Surface"))
            .accessibilityIdentifier("MobileSurfaceDeckAdd")
        }
    }

    private func scrollToSelection(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedSurfaceID = value.selectedSurfaceID else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(selectedSurfaceID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedSurfaceID, anchor: .center)
        }
    }

    private func statusColor(_ kind: ChatAgentStateKind) -> Color {
        switch kind {
        case .working:
            return .green
        case .needsInput:
            return .orange
        }
    }

    private func systemImage(for type: MobilePaneSurfaceType) -> String {
        switch type {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .agentSession:
            return "sparkles"
        case .workspaceTodo:
            return "checklist"
        case .filepreview:
            return "doc"
        case .project:
            return "folder"
        case .rightSidebarTool, .customSidebar, .extensionBrowser, .cloudVMLoading, .other:
            return "rectangle"
        }
    }

    private func chipAccessibilityLabel(
        _ chip: SurfaceDeckValue.Chip,
        paneNumber: Int,
        paneCount: Int
    ) -> String {
        if chip.isTerminal {
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.surfaceDeck.chip.terminalInPane",
                    defaultValue: "%@, terminal, pane %d of %d"
                ),
                chip.title,
                paneNumber,
                paneCount
            )
        }
        return String.localizedStringWithFormat(
            L10n.string(
                "mobile.surfaceDeck.chip.unavailableInPane",
                defaultValue: "%@, unavailable on iPhone, pane %d of %d"
            ),
            chip.title,
            paneNumber,
            paneCount
        )
    }

    private func paneAccessibilityLabel(number: Int, totalCount: Int) -> String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.paneMap.panePosition",
                defaultValue: "Pane %d of %d"
            ),
            number,
            totalCount
        )
    }

    private func statusAccessibilityValue(_ kind: ChatAgentStateKind?) -> String {
        switch kind {
        case .working:
            return L10n.string(
                "mobile.agent.status.working",
                defaultValue: "Agent working"
            )
        case .needsInput:
            return L10n.string(
                "mobile.agent.status.needsInput",
                defaultValue: "Agent needs input"
            )
        case nil:
            return ""
        }
    }
}
