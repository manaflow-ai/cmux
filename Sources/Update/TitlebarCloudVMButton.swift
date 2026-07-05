import SwiftUI
import AppKit
import CmuxSettings

enum TitlebarNewWorkspaceCloudSplitButtonMetrics {
    static func primaryWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(config.iconSize + 4, config.buttonSize - 3)
    }

    static func dropdownWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(14, floor(config.buttonSize * 0.70))
    }

    static func dropdownIconSize(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(6, config.iconSize - 6)
    }

    static func totalWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        primaryWidth(config: config) + dropdownWidth(config: config)
    }
}

struct TitlebarNewWorkspaceCloudSplitButton: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    let onNewTab: () -> Void
    @State private var cloudMenuAnchorView: NSView?
    @State private var hoveredSegment: TitlebarNewWorkspaceCloudSplitButtonSegment?

    private var dropdownWidth: CGFloat {
        TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownWidth(config: config)
    }

    private var primaryWidth: CGFloat {
        TitlebarNewWorkspaceCloudSplitButtonMetrics.primaryWidth(config: config)
    }

    private var isHovering: Bool {
        hoveredSegment != nil
    }

    private var foregroundOpacity: Double {
        titlebarControlForegroundOpacity(isHovering: isHovering, isPressed: false, isEnabled: true)
    }

    private var borderOpacity: Double {
        titlebarControlBorderOpacity(config: config, isHovering: isHovering, isPressed: false, isEnabled: true)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: config.iconSize, weight: .medium))
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
                    Image(systemName: "chevron.down")
                        .font(.system(
                            size: TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownIconSize(config: config),
                            weight: .bold
                        ))
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
        .frame(width: TitlebarNewWorkspaceCloudSplitButtonMetrics.totalWidth(config: config), height: config.buttonSize)
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
            Image(systemName: "cloud")
                .font(.system(size: config.iconSize, weight: .medium))
                .frame(width: config.buttonSize, height: config.buttonSize)
        }
        .safeHelp(String(localized: "titlebar.cloudVM.tooltip", defaultValue: "Open Base"))
    }

    @MainActor
    static func showCloudVMMenu(anchorView: NSView, event: NSEvent) {
        NSMenu.popUpContextMenu(makeCloudVMMenu(), with: event, for: anchorView)
    }

    @MainActor
    static func showCloudVMMenu(anchorView: NSView) {
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
            title: String(localized: "command.cloudVM.open.title", defaultValue: "Open Base"),
            action: {
                CloudVMMenuTarget.shared.open()
            }
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.fork.title", defaultValue: "Fork Cloud VM"),
            action: #selector(CloudVMMenuTarget.fork)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Cloud VM"),
            action: #selector(CloudVMMenuTarget.snapshot)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Checkpoint..."),
            action: #selector(CloudVMMenuTarget.restore)
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(advancedMenuItem())
    }

    private static func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = CloudVMMenuTarget.shared
        return item
    }

    private static func mouseDownMenuItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = menuItem(title: title, action: #selector(CloudVMMenuTarget.open))
        item.view = CloudVMMouseDownMenuItemView(title: title, action: action)
        return item
    }

    private static func advancedMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "command.cloudVM.advanced.title", defaultValue: "Advanced"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.status.title", defaultValue: "Status"),
            action: #selector(CloudVMMenuTarget.status)
        ))
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.ports.title", defaultValue: "Ports"),
            action: #selector(CloudVMMenuTarget.ports)
        ))
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote to Template"),
            action: #selector(CloudVMMenuTarget.promoteTemplate)
        ))
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Tools"),
            action: #selector(CloudVMMenuTarget.tools)
        ))
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.handoff.title", defaultValue: "Agent Handoff"),
            action: #selector(CloudVMMenuTarget.handoff)
        ))
        item.submenu = submenu
        return item
    }
}

@MainActor
private final class CloudVMMenuTarget: NSObject {
    static let shared = CloudVMMenuTarget()

    @objc func open() {
        _ = AppDelegate.shared?.performCloudVMAction(debugSource: "titlebar.cloudVM.menu.open")
    }

    @objc func fork() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.fork, debugSource: "titlebar.cloudVM.menu.fork")
    }

    @objc func snapshot() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.snapshot, debugSource: "titlebar.cloudVM.menu.snapshot")
    }

    @objc func restore() {
        _ = AppDelegate.shared?.performCloudVMRestoreCommand(debugSource: "titlebar.cloudVM.menu.restore")
    }

    @objc func promoteTemplate() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.promoteTemplate, debugSource: "titlebar.cloudVM.menu.promoteTemplate")
    }

    @objc func status() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.status, debugSource: "titlebar.cloudVM.menu.status")
    }

    @objc func ports() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.ports, debugSource: "titlebar.cloudVM.menu.ports")
    }

    @objc func tools() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.tools, debugSource: "titlebar.cloudVM.menu.tools")
    }

    @objc func handoff() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.handoff, debugSource: "titlebar.cloudVM.menu.handoff")
    }
}

@MainActor
private final class CloudVMMouseDownMenuItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
            titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        }
    }

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        wantsLayer = true
        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        enclosingMenuItem?.menu?.cancelTrackingWithoutAnimation()
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        bounds.insetBy(dx: 5, dy: 2).fill()
    }
}
