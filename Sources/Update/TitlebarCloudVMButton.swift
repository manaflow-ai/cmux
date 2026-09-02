import SwiftUI
import AppKit
import CmuxSettings

enum TitlebarNewWorkspaceCloudSplitButtonMetrics {
    static func primaryWidth(config: TitlebarControlsStyleConfig) -> CGFloat { max(config.iconSize + 4, config.buttonSize - 3) }

    static func dropdownWidth(config: TitlebarControlsStyleConfig) -> CGFloat { max(14, floor(config.buttonSize * 0.70)) }

    static func dropdownIconSize(config: TitlebarControlsStyleConfig) -> CGFloat { max(6, config.iconSize - 6) }

    static func totalWidth(config: TitlebarControlsStyleConfig) -> CGFloat { primaryWidth(config: config) + dropdownWidth(config: config) }
}

#if DEBUG
enum TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment: String, CaseIterable, Identifiable {
    case newTab
    case cloudMenu
    case both

    var id: String { rawValue }

    static func stored(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .newTab
    }

    fileprivate func includes(_ segment: TitlebarNewWorkspaceCloudSplitButtonSegment) -> Bool {
        switch (self, segment) {
        case (.newTab, .newTab), (.cloudMenu, .cloudMenu), (.both, _):
            return true
        default:
            return false
        }
    }
}

enum TitlebarNewWorkspaceCloudSplitButtonDebugSettings {
    static let alwaysHoverKey = "debugTitlebarSplitButtonAlwaysHover"
    static let forcedHoverSegmentKey = "debugTitlebarSplitButtonForcedHoverSegment"
    static let plusWidthOffsetKey = "debugTitlebarSplitButtonPlusWidthOffset"
    static let caretWidthOffsetKey = "debugTitlebarSplitButtonCaretWidthOffset"
    static let plusPaddingTopKey = "debugTitlebarSplitButtonPlusPaddingTop"
    static let plusPaddingLeadingKey = "debugTitlebarSplitButtonPlusPaddingLeading"
    static let plusPaddingBottomKey = "debugTitlebarSplitButtonPlusPaddingBottom"
    static let plusPaddingTrailingKey = "debugTitlebarSplitButtonPlusPaddingTrailing"
    static let caretPaddingTopKey = "debugTitlebarSplitButtonCaretPaddingTop"
    static let caretPaddingLeadingKey = "debugTitlebarSplitButtonCaretPaddingLeading"
    static let caretPaddingBottomKey = "debugTitlebarSplitButtonCaretPaddingBottom"
    static let caretPaddingTrailingKey = "debugTitlebarSplitButtonCaretPaddingTrailing"

    static let defaultAlwaysHover = false
    static let defaultForcedHoverSegment = TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment.newTab
    static let defaultPlusWidthOffset = -12.0
    static let defaultCaretWidthOffset = -10.0
    static let defaultPadding = 0.0
    static let defaultPlusPaddingTrailing = -0.7
}
#endif

struct TitlebarNewWorkspaceCloudSplitButton: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    let onNewTab: () -> Void
    @State private var cloudMenuAnchorView: NSView?
    @State private var hoveredSegment: TitlebarNewWorkspaceCloudSplitButtonSegment?
#if DEBUG
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.alwaysHoverKey)
    private var debugAlwaysHover = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultAlwaysHover
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.forcedHoverSegmentKey)
    private var debugForcedHoverSegmentRaw = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultForcedHoverSegment.rawValue
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusWidthOffsetKey)
    private var debugPlusWidthOffset = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPlusWidthOffset
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretWidthOffsetKey)
    private var debugCaretWidthOffset = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultCaretWidthOffset
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingTopKey)
    private var debugPlusPaddingTop = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingLeadingKey)
    private var debugPlusPaddingLeading = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingBottomKey)
    private var debugPlusPaddingBottom = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingTrailingKey)
    private var debugPlusPaddingTrailing = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPlusPaddingTrailing
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingTopKey)
    private var debugCaretPaddingTop = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingLeadingKey)
    private var debugCaretPaddingLeading = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingBottomKey)
    private var debugCaretPaddingBottom = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
    @AppStorage(TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingTrailingKey)
    private var debugCaretPaddingTrailing = TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding
#endif

    private var dropdownWidth: CGFloat {
        let baseWidth = TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownWidth(config: config)
#if DEBUG
        return max(
            TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownIconSize(config: config) + 4,
            baseWidth + CGFloat(debugCaretWidthOffset)
        )
#else
        return baseWidth
#endif
    }

    private var primaryWidth: CGFloat {
        let baseWidth = TitlebarNewWorkspaceCloudSplitButtonMetrics.primaryWidth(config: config)
#if DEBUG
        return max(config.iconSize + 4, baseWidth + CGFloat(debugPlusWidthOffset))
#else
        return baseWidth
#endif
    }

    private var isHovering: Bool {
#if DEBUG
        if debugAlwaysHover {
            return true
        }
#endif
        return hoveredSegment != nil
    }

    private var foregroundOpacity: Double {
        titlebarControlForegroundOpacity(isHovering: isHovering, isPressed: false, isEnabled: true)
    }

    private var borderOpacity: Double {
        titlebarControlBorderOpacity(config: config, isHovering: isHovering, isPressed: false, isEnabled: true)
    }

#if DEBUG
    private var debugForcedHoverSegment: TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment {
        TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment.stored(rawValue: debugForcedHoverSegmentRaw)
    }
#endif

    private var plusIconPadding: EdgeInsets {
#if DEBUG
        EdgeInsets(
            top: CGFloat(debugPlusPaddingTop),
            leading: CGFloat(debugPlusPaddingLeading),
            bottom: CGFloat(debugPlusPaddingBottom),
            trailing: CGFloat(debugPlusPaddingTrailing)
        )
#else
        EdgeInsets()
#endif
    }

    private var caretIconPadding: EdgeInsets {
#if DEBUG
        EdgeInsets(
            top: CGFloat(debugCaretPaddingTop),
            leading: CGFloat(debugCaretPaddingLeading),
            bottom: CGFloat(debugCaretPaddingBottom),
            trailing: CGFloat(debugCaretPaddingTrailing)
        )
#else
        EdgeInsets()
#endif
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onNewTab) {
                CmuxSystemSymbolImage(systemName: "plus", pointSize: config.iconSize, weight: .medium)
                    .padding(plusIconPadding)
                    .frame(width: primaryWidth, height: config.buttonSize)
            }
            .buttonStyle(.plain)
            .frame(width: primaryWidth, height: config.buttonSize)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("titlebarControl.newTab")
            .accessibilityLabel(String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"))
            .overlay {
                TitlebarSplitButtonRightClickView { anchorView, event in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(anchorView: anchorView, event: event)
                }
            }
            .background(foregroundColor.opacity(segmentBackgroundOpacity(for: .newTab)))
            .onHover { hovering in
                updateHoveredSegment(.newTab, hovering: hovering)
            }
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))

            Button(
                action: {
                    if let cloudMenuAnchorView {
                        _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                            anchorView: cloudMenuAnchorView,
                            debugSource: "titlebar.newWorkspace.cloudMenu"
                        )
                    } else {
                        _ = AppDelegate.shared?.performCloudVMAction(debugSource: "titlebar.newWorkspace.cloudMenu.fallback")
                    }
                }
            ) {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    CmuxSystemSymbolImage(
                        systemName: "chevron.down",
                        pointSize: TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownIconSize(config: config),
                        weight: .bold
                    )
                        .padding(caretIconPadding)
                }
                .frame(width: dropdownWidth, height: config.buttonSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: dropdownWidth, height: config.buttonSize)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("titlebarControl.cloudVM")
            .accessibilityLabel(String(localized: "titlebar.cloudVM.menu.accessibilityLabel", defaultValue: "Cloud VM Menu"))
            .background(TitlebarControlAnchorView { cloudMenuAnchorView = $0 })
            .overlay {
                TitlebarSplitButtonRightClickView { anchorView, event in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                        anchorView: anchorView,
                        event: event,
                        debugSource: "titlebar.newWorkspace.cloudMenu.rightClick"
                    )
                }
            }
            .background(foregroundColor.opacity(segmentBackgroundOpacity(for: .cloudMenu)))
            .onHover { hovering in
                updateHoveredSegment(.cloudMenu, hovering: hovering)
            }
            .safeHelp(String(localized: "titlebar.cloudVM.menu.tooltip", defaultValue: "Cloud VM actions"))
        }
        .foregroundStyle(foregroundColor.opacity(foregroundOpacity))
        .frame(width: primaryWidth + dropdownWidth, height: config.buttonSize)
        .background {
            if config.buttonBackground && !isHovering {
                RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous))
        .overlay {
            if borderOpacity > 0 {
                RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                    .stroke(foregroundColor.opacity(borderOpacity), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: hoveredSegment)
        .background(TitlebarChromeGeometryReporter(keyPrefix: "titlebarControl_newTabCloudSplit"))
        .titlebarInteractiveControl()
    }

    private func segmentBackgroundOpacity(for segment: TitlebarNewWorkspaceCloudSplitButtonSegment) -> Double {
#if DEBUG
        if debugAlwaysHover {
            if debugForcedHoverSegment.includes(segment) {
                return titlebarControlActiveHoverBackgroundOpacity(
                    isHovering: true,
                    isPressed: false,
                    isEnabled: true
                )
            }
            return titlebarControlPassiveHoverBackgroundOpacity(
                isHovering: true,
                isPressed: false,
                isEnabled: true
            )
        }
#endif
        if hoveredSegment == segment {
            return titlebarControlActiveHoverBackgroundOpacity(
                isHovering: isHovering,
                isPressed: false,
                isEnabled: true
            )
        }
        return titlebarControlPassiveHoverBackgroundOpacity(
            isHovering: isHovering,
            isPressed: false,
            isEnabled: true
        )
    }

    private func updateHoveredSegment(
        _ segment: TitlebarNewWorkspaceCloudSplitButtonSegment,
        hovering: Bool
    ) {
        guard titlebarControlsShouldTrackButtonHover(config: config) else { return }
        if hovering {
            hoveredSegment = segment
        } else if hoveredSegment == segment {
            hoveredSegment = nil
        }
    }
}

private enum TitlebarNewWorkspaceCloudSplitButtonSegment: Equatable {
    case newTab
    case cloudMenu
}

private struct TitlebarSplitButtonRightClickView: NSViewRepresentable {
    let onRightMouseDown: (NSView, NSEvent) -> Void

    func makeNSView(context: Context) -> TitlebarSplitButtonRightClickNSView {
        let view = TitlebarSplitButtonRightClickNSView()
        view.onRightMouseDown = onRightMouseDown
        return view
    }

    func updateNSView(_ nsView: TitlebarSplitButtonRightClickNSView, context: Context) {
        nsView.onRightMouseDown = onRightMouseDown
    }
}

private final class TitlebarSplitButtonRightClickNSView: NSView {
    var onRightMouseDown: ((NSView, NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              NSApp.currentEvent?.type == .rightMouseDown else {
            return nil
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(self, event)
    }
}

struct TitlebarCloudVMButton: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color

    var body: some View {
        TitlebarControlButton(
            config: config,
            foregroundColor: foregroundColor,
            accessibilityIdentifier: "titlebarControl.cloudVM",
            accessibilityLabel: String(localized: "titlebar.cloudVM.accessibilityLabel", defaultValue: "Cloud VM"),
            action: {
#if DEBUG
                cmuxDebugLog("titlebar.cloudVM")
#endif
                _ = AppDelegate.shared?.performCloudVMAction(debugSource: "titlebar.cloudVM")
            },
            rightClickAction: { anchorView, event in
                Self.showCloudVMMenu(anchorView: anchorView, event: event)
            }
        ) {
            CmuxSystemSymbolImage(systemName: "cloud", pointSize: config.iconSize, weight: .medium)
                .frame(width: config.buttonSize, height: config.buttonSize)
        }
        .safeHelp(String(localized: "titlebar.cloudVM.tooltip", defaultValue: "Open Base"))
    }

    @MainActor
    static func showCloudVMMenu(anchorView: NSView, event: NSEvent) {
        guard CloudMachinesFeature.isEnabled else { return }
        NSMenu.popUpContextMenu(makeCloudVMMenu(), with: event, for: anchorView)
    }

    @MainActor
    static func showCloudVMMenu(anchorView: NSView) {
        guard CloudMachinesFeature.isEnabled else { return }
        let menu = makeCloudVMMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
    }

    @MainActor
    static func makeCloudVMMenu() -> NSMenu {
        let menu = NSMenu()
        appendCloudVMMenuItems(to: menu)
        return menu
    }

    @MainActor
    static func appendCloudVMMenuItems(to menu: NSMenu) {
        menu.addItem(mouseDownMenuItem(
            title: String(localized: "command.cloudVM.new.title", defaultValue: "New Cloud VM"),
            action: {
                CloudVMMenuTarget.shared.newMachine()
            }
        ))
    }

    private static func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = CloudVMMenuTarget.shared
        return item
    }

    private static func mouseDownMenuItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = menuItem(title: title, action: #selector(CloudVMMenuTarget.newMachine))
        item.view = MouseDownMenuItemView(title: title, action: action)
        return item
    }
}

@MainActor
private final class CloudVMMenuTarget: NSObject {
    static let shared = CloudVMMenuTarget()

    /// Same path as the Machines panel ＋ button and the command palette: the
    /// New Machine sheet, with the plan meter read from the fleet page first.
    @objc func newMachine() {
        NewMachineSheetPresenter.shared.presentNewMachineFetchingPlan(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }
}
