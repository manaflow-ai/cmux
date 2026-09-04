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
        HStack(spacing: 6) {
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
                    Image(systemName: model.groupKey.symbolName)
                        .cmuxFont(
                            size: RightSidebarChromeControlStyle.secondaryIconSize,
                            weight: RightSidebarChromeControlStyle.iconWeight
                        )
                    Text(model.groupKey.label)
                        .cmuxFont(
                            size: RightSidebarChromeControlStyle.labelSize,
                            weight: RightSidebarChromeControlStyle.labelWeight
                        )
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(
                localized: "vaultHistory.groupPicker.tooltip",
                defaultValue: "Group history by"
            ))
            .accessibilityIdentifier("VaultHistoryGroupPicker")
            .titlebarInteractiveControl()

            Spacer(minLength: 4)

            Button {
                hasFreshSessionSnapshot = false
                sessionReloadGeneration &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .cmuxFont(size: 10, weight: .medium)
            }
            .buttonStyle(.borderless)
            .help(reloadLabel)
            .accessibilityLabel(reloadLabel)
            .disabled(model.isLoading || sessionStore.isLoading)
            .titlebarInteractiveControl()
        }
        .rightSidebarChromeBar()
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
        VStack(spacing: 4) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timelineList: some View {
        let groups = model.groups
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.events) { event in
                            VaultHistoryEventRow(event: event)
                        }
                    } header: {
                        VaultHistoryGroupHeader(title: group.title, count: group.events.count)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
