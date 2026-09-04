import AppKit
import CmuxVaultHistory
import CmuxFoundation
import SwiftUI

/// The Vault History tab: a unified timeline of workspace, window, and session activity.
struct VaultHistoryView: View {
    @ObservedObject var sessionStore: SessionIndexStore
    let log: VaultHistoryEventLog
    let chromeBackgroundColor: NSColor
    @State private var model: VaultHistoryTimelineModel

    init(
        sessionStore: SessionIndexStore,
        log: VaultHistoryEventLog,
        chromeBackgroundColor: NSColor
    ) {
        self.sessionStore = sessionStore
        self.log = log
        self.chromeBackgroundColor = chromeBackgroundColor
        _model = State(initialValue: VaultHistoryTimelineModel(log: log))
    }

    var body: some View {
        VaultHistoryContentView(
            sessionStore: sessionStore,
            log: log,
            model: model,
            chromeBackgroundColor: chromeBackgroundColor
        )
    }
}

private struct VaultHistoryContentView: View {
    @ObservedObject var sessionStore: SessionIndexStore
    let log: VaultHistoryEventLog
    let model: VaultHistoryTimelineModel
    let chromeBackgroundColor: NSColor
    @State private var sessionReloadGeneration = 0
    @State private var hasFreshSessionSnapshot = false
    @State private var isGroupPickerHovered = false
    @State private var isReloadHovered = false

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if !model.didLoad {
                loadingView
            } else if model.groups.isEmpty {
                emptyView
            } else {
                timelineList
            }
        }
        .task(id: sessionReloadGeneration) {
            let entries = await sessionStore.reloadAndWaitForFreshEntries()
            guard !Task.isCancelled else { return }
            hasFreshSessionSnapshot = true
            model.refresh(sessionEntries: entries)
        }
        .onChange(of: sessionStore.entries) { _, entries in
            guard hasFreshSessionSnapshot else { return }
            model.refresh(sessionEntries: entries)
        }
        .onChange(of: log.revision) { _, _ in
            guard hasFreshSessionSnapshot else { return }
            model.refresh(sessionEntries: sessionStore.entries)
        }
    }

    private var controlBar: some View {
        HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
            Menu {
                ForEach(VaultHistoryGroupKey.allCases) { key in
                    Button {
                        model.groupKey = key
                    } label: {
                        if model.groupKey == key {
                            Label(key.label, systemImage: "checkmark")
                        } else {
                            Text(key.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    CmuxSystemSymbolImage(
                        magnified: model.groupKey.symbolName,
                        pointSize: RightSidebarChromeControlStyle.secondaryIconSize,
                        weight: RightSidebarChromeControlStyle.iconWeight
                    )
                    Text(model.groupKey.label)
                        .cmuxFont(
                            size: RightSidebarChromeControlStyle.labelSize,
                            weight: RightSidebarChromeControlStyle.labelWeight
                        )
                }
                .rightSidebarChromePill(
                    isSelected: false,
                    isHovered: isGroupPickerHovered,
                    geometryKeyPrefix: "VaultHistoryGroupPickerControl"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(
                localized: "vaultHistory.groupPicker.tooltip",
                defaultValue: "Group history by"
            ))
            .accessibilityIdentifier("VaultHistoryGroupPicker")
            .titlebarInteractiveControl()
            .onHover { isGroupPickerHovered = $0 }

            Spacer(minLength: 4)

            Button {
                hasFreshSessionSnapshot = false
                sessionReloadGeneration &+= 1
            } label: {
                HeaderChromeIconStyle.symbol("arrow.clockwise")
                    .foregroundStyle(
                        HeaderChromeIconStyle.foregroundColor.opacity(
                            isReloadHovered
                                ? HeaderChromeIconStyle.hoveredOpacity
                                : HeaderChromeIconStyle.opacity
                        )
                    )
                    .frame(
                        width: RightSidebarChromeMetrics.headerControlSize,
                        height: RightSidebarChromeMetrics.headerControlSize
                    )
                    .background {
                        if isReloadHovered {
                            RoundedRectangle(
                                cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius,
                                style: .continuous
                            )
                            .fill(Color.primary.opacity(0.07))
                        }
                    }
            }
            .buttonStyle(.borderless)
            .help(reloadLabel)
            .accessibilityLabel(reloadLabel)
            .disabled(model.isLoading || sessionStore.isLoading)
            .titlebarInteractiveControl()
            .onHover { isReloadHovered = $0 }
        }
        .rightSidebarChromeBar(
            leadingPadding: 4,
            trailingPadding: 6,
            height: RightSidebarChromeMetrics.secondaryBarHeight
        )
        .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
    }

    private var reloadLabel: String {
        String(
            localized: "vaultHistory.reload.tooltip",
            defaultValue: "Reload History"
        )
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            CmuxSystemSymbolImage(
                magnified: "clock.arrow.circlepath",
                pointSize: 22,
                weight: .regular
            )
                .foregroundColor(.secondary.opacity(0.65))
            ProgressView().controlSize(.small)
            Text(String(
                localized: "vaultHistory.loading",
                defaultValue: "Loading history…"
            ))
            .cmuxFont(size: 11)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 7) {
            CmuxSystemSymbolImage(
                magnified: "clock.arrow.circlepath",
                pointSize: 28,
                weight: .light
            )
                .foregroundColor(.secondary.opacity(0.55))
            Text(String(
                localized: "vaultHistory.empty.title",
                defaultValue: "No history yet"
            ))
            .cmuxFont(size: 12)
            .foregroundColor(.secondary)
            Text(String(
                localized: "vaultHistory.empty.subtitle",
                defaultValue: "Workspace, window, and agent session activity will appear here."
            ))
            .cmuxFont(size: 11)
            .foregroundColor(.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var timelineList: some View {
        let groups = model.groups
        let backgroundHex = chromeBackgroundColor.hexString()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.events) { event in
                            VaultHistoryEventRow(event: event)
                                .equatable()
                        }
                    } header: {
                        VaultHistoryGroupHeader(
                            title: group.title,
                            count: group.events.count,
                            key: group.key,
                            backgroundHex: backgroundHex
                        )
                        .equatable()
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
