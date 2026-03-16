import SwiftUI
import Bonsplit
import AppKit

struct WorkspaceTopTabBarView: View {
    @ObservedObject var workspace: Workspace
    let isWorkspaceInputActive: Bool

    private var appearance: BonsplitConfiguration.Appearance {
        workspace.bonsplitController.configuration.appearance
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TabBarMetrics.tabSpacing) {
                    ForEach(workspace.topTabs, id: \.id) { topTab in
                        let topTabIdsToLeft = workspace.topTabIdsToLeft(of: topTab.id)
                        let topTabIdsToRight = workspace.topTabIdsToRight(of: topTab.id)
                        let topTabIdsToCloseOthers = workspace.topTabIdsToCloseOthers(of: topTab.id)
                        WorkspaceTopTabItemView(
                            title: workspace.topTabTitle(topTab),
                            isSelected: workspace.selectedTopTabId == topTab.id,
                            showsCloseButton: workspace.topTabs.count > 1,
                            hasCustomTitle: workspace.topTabHasCustomTitle(topTab),
                            canCloseToLeft: !topTabIdsToLeft.isEmpty,
                            canCloseToRight: !topTabIdsToRight.isEmpty,
                            canCloseOthers: !topTabIdsToCloseOthers.isEmpty,
                            appearance: appearance,
                            onSelect: {
                                workspace.selectTopTab(topTab)
                            },
                            onRename: {
                                workspace.selectTopTab(topTab)
                                workspace.promptRenameTopTab(topTabId: topTab.id)
                            },
                            onClearCustomTitle: {
                                workspace.setTopTabCustomTitle(topTabId: topTab.id, title: nil)
                            },
                            onNewTab: {
                                workspace.selectTopTab(topTab)
                                _ = workspace.addTopTab(select: true)
                            },
                            onCloseToLeft: {
                                workspace.selectTopTab(topTab)
                                workspace.requestCloseTopTabs(topTabIdsToLeft)
                            },
                            onCloseToRight: {
                                workspace.selectTopTab(topTab)
                                workspace.requestCloseTopTabs(topTabIdsToRight)
                            },
                            onCloseOthers: {
                                workspace.selectTopTab(topTab)
                                workspace.requestCloseTopTabs(topTabIdsToCloseOthers)
                            },
                            onClose: {
                                workspace.selectTopTab(topTab)
                                workspace.requestCloseTopTab(topTab.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, TabBarMetrics.barPadding)
            }

            Button {
                _ = workspace.addTopTab(select: true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                    .frame(width: 28, height: TabBarMetrics.tabHeight)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(String(localized: "workspace.topTab.new.help", defaultValue: "New Tab"))
        }
        .frame(height: TabBarMetrics.barHeight)
        .background(
            Rectangle()
                .fill(
                    isWorkspaceInputActive
                        ? TabBarColors.barBackground(for: appearance)
                        : TabBarColors.barBackground(for: appearance).opacity(0.95)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(TabBarColors.separator(for: appearance))
                        .frame(height: 1)
                }
        )
    }
}

private struct WorkspaceTopTabItemView: View {
    let title: String
    let isSelected: Bool
    let showsCloseButton: Bool
    let hasCustomTitle: Bool
    let canCloseToLeft: Bool
    let canCloseToRight: Bool
    let canCloseOthers: Bool
    let appearance: BonsplitConfiguration.Appearance
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClearCustomTitle: () -> Void
    let onNewTab: () -> Void
    let onCloseToLeft: () -> Void
    let onCloseToRight: () -> Void
    let onCloseOthers: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: TabBarMetrics.contentSpacing) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: max(10, TabBarMetrics.iconSize - 2.5)))
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )

                Text(title)
                    .font(.system(size: TabBarMetrics.titleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
            }

            Spacer(minLength: 0)

            if showsCloseButton {
                Group {
                    if isSelected || isHovered || isCloseHovered {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                                .foregroundStyle(
                                    isCloseHovered
                                        ? TabBarColors.activeText(for: appearance)
                                        : TabBarColors.inactiveText(for: appearance)
                                )
                                .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                                .background(
                                    Circle()
                                        .fill(
                                            isCloseHovered
                                                ? TabBarColors.hoveredTabBackground(for: appearance)
                                                : .clear
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isCloseHovered = hovering
                        }
                    } else {
                        Color.clear
                            .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                    }
                }
            }
        }
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .offset(y: isSelected ? 0.5 : 0)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            maxWidth: TabBarMetrics.tabMaxWidth,
            minHeight: TabBarMetrics.tabHeight,
            maxHeight: TabBarMetrics.tabHeight
        )
        .padding(.bottom, isSelected ? 1 : 0)
        .background(tabBackground)
        .contentShape(Rectangle())
        .background(TopTabMiddleClickMonitorView(onMiddleClick: {
            guard showsCloseButton else { return }
            onClose()
        }))
        .contextMenu {
            Button(String(localized: "command.newTerminalTab.title", defaultValue: "New Tab")) {
                onNewTab()
            }
            Divider()
            Button(String(localized: "command.renameTab.title", defaultValue: "Rename Tab…")) {
                onRename()
            }
            if hasCustomTitle {
                Button(String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name")) {
                    onClearCustomTitle()
                }
            }
            if showsCloseButton {
                Divider()
                Button(String(localized: "command.closeTab.title", defaultValue: "Close Tab")) {
                    onClose()
                }
                Button(String(localized: "command.closeTabsToLeft.title", defaultValue: "Close Tabs to Left")) {
                    onCloseToLeft()
                }
                .disabled(!canCloseToLeft)
                Button(String(localized: "command.closeTabsToRight.title", defaultValue: "Close Tabs to Right")) {
                    onCloseToRight()
                }
                .disabled(!canCloseToRight)
                Button(String(localized: "command.closeOtherTabs.title", defaultValue: "Close Other Tabs")) {
                    onCloseOthers()
                }
                .disabled(!canCloseOthers)
            }
        }
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var tabBackground: some View {
        ZStack(alignment: .top) {
            if isHovered && !isSelected {
                Rectangle()
                    .fill(TabBarColors.hoveredTabBackground(for: appearance))
            } else {
                Color.clear
            }

            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: TabBarMetrics.activeIndicatorHeight)
            }

            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator(for: appearance))
                    .frame(width: 1)
            }
        }
    }
}

private struct TopTabMiddleClickMonitorView: NSViewRepresentable {
    let onMiddleClick: () -> Void

    final class Coordinator {
        var onMiddleClick: (() -> Void)?
        weak var view: NSView?
        var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view
        context.coordinator.onMiddleClick = onMiddleClick

        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak coordinator] event in
            guard event.buttonNumber == 2 else { return event }
            guard let coordinator, let view = coordinator.view, let window = view.window else { return event }
            guard event.window === window else { return event }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }

            coordinator.onMiddleClick?()
            return nil
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onMiddleClick = onMiddleClick
    }
}
