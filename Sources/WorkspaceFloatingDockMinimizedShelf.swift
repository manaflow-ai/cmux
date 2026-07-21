import AppKit
import CmuxAppKitSupportUI
import Observation
import SwiftUI

enum WorkspaceFloatingDockMinimizeDestination: String, CaseIterable, Identifiable {
    case bottomRightPill
    case bottomShelf
    case topTray
    case leftRail
    case paletteOnly

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .bottomRightPill:
            "debug.floatingDockMinimize.destination.bottomRightPill"
        case .bottomShelf:
            "debug.floatingDockMinimize.destination.bottomShelf"
        case .topTray:
            "debug.floatingDockMinimize.destination.topTray"
        case .leftRail:
            "debug.floatingDockMinimize.destination.leftRail"
        case .paletteOnly:
            "debug.floatingDockMinimize.destination.paletteOnly"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .bottomRightPill:
            "debug.floatingDockMinimize.destination.bottomRightPill.detail"
        case .bottomShelf:
            "debug.floatingDockMinimize.destination.bottomShelf.detail"
        case .topTray:
            "debug.floatingDockMinimize.destination.topTray.detail"
        case .leftRail:
            "debug.floatingDockMinimize.destination.leftRail.detail"
        case .paletteOnly:
            "debug.floatingDockMinimize.destination.paletteOnly.detail"
        }
    }

    var usesVerticalLayout: Bool { self == .leftRail }
    var usesCompactIconLayout: Bool { self == .bottomRightPill }
}

enum WorkspaceFloatingDockMinimizeDebugSettings {
    static let destinationKey = "debugWorkspaceFloatingDockMinimizeDestination"
    static let defaultDestination = WorkspaceFloatingDockMinimizeDestination.bottomRightPill

    static func currentDestination(
        defaults: UserDefaults = .standard
    ) -> WorkspaceFloatingDockMinimizeDestination {
        WorkspaceFloatingDockMinimizeDestination(
            rawValue: defaults.string(forKey: destinationKey) ?? ""
        ) ?? defaultDestination
    }
}

struct WorkspaceFloatingDockMinimizedShelfLayout {
    static func frame(
        parentFrame: CGRect,
        itemCount: Int,
        destination: WorkspaceFloatingDockMinimizeDestination
    ) -> CGRect? {
        guard itemCount > 0, destination != .paletteOnly else { return nil }

        switch destination {
        case .bottomRightPill:
            let availableWidth = max(50, parentFrame.width - 48)
            let width = min(max(50, CGFloat(itemCount) * 38 + 8), min(440, availableWidth))
            let height: CGFloat = 50
            return CGRect(
                x: parentFrame.maxX - width - 24,
                y: parentFrame.minY + 24,
                width: width,
                height: height
            )
        case .bottomShelf, .topTray:
            let availableWidth = max(220, parentFrame.width - 48)
            let width = min(max(220, CGFloat(itemCount) * 164 + 20), min(760, availableWidth))
            let height: CGFloat = 48
            let x = parentFrame.midX - width / 2
            let y = destination == .bottomShelf
                ? parentFrame.minY + 24
                : parentFrame.maxY - height - 52
            return CGRect(x: x, y: y, width: width, height: height)
        case .leftRail:
            let width: CGFloat = 196
            let availableHeight = max(80, parentFrame.height - 96)
            let height = min(max(52, CGFloat(itemCount) * 38 + 16), min(440, availableHeight))
            return CGRect(
                x: parentFrame.minX + 20,
                y: parentFrame.midY - height / 2,
                width: width,
                height: height
            )
        case .paletteOnly:
            return nil
        }
    }

    static func animationTargetFrame(
        parentFrame: CGRect,
        itemCount: Int,
        destination: WorkspaceFloatingDockMinimizeDestination
    ) -> CGRect {
        if destination == .bottomRightPill,
           let shelfFrame = frame(
               parentFrame: parentFrame,
               itemCount: max(1, itemCount),
               destination: destination
           ) {
            return CGRect(
                x: shelfFrame.maxX - 43,
                y: shelfFrame.minY + 7,
                width: 36,
                height: 36
            )
        }

        if let shelfFrame = frame(
            parentFrame: parentFrame,
            itemCount: max(1, itemCount),
            destination: destination
        ) {
            return CGRect(
                x: shelfFrame.midX - 18,
                y: shelfFrame.midY - 18,
                width: 36,
                height: 36
            )
        }

        return CGRect(
            x: parentFrame.midX - 18,
            y: parentFrame.minY + 31,
            width: 36,
            height: 36
        )
    }
}

struct WorkspaceFloatingDockMinimizedShelfItem: Identifiable, Equatable {
    let id: UUID
    let title: String
}

@MainActor
final class WorkspaceFloatingDockMinimizedShelfController: NSObject {
    private weak var parentWindow: NSWindow?
    private let panel: NSPanel
    private let glassEffect = WindowGlassEffect()
    private var destination = WorkspaceFloatingDockMinimizeDestination.paletteOnly
    private var itemCount = 0

    init(parentWindow: NSWindow) {
        self.parentWindow = parentWindow
        self.panel = WorkspaceFloatingDockMinimizedShelfPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.identifier = NSUserInterfaceItemIdentifier("cmux.workspace.float.minimizedShelf")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = WorkspaceFloatingDockMinimizedShelfHostingView(
            rootView: AnyView(EmptyView())
        )

        glassEffect.changesTintWithWindowKeyState = false
        applyGlassBackdrop()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(parentFrameDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: parentWindow
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(
        items: [WorkspaceFloatingDockMinimizedShelfItem],
        destination: WorkspaceFloatingDockMinimizeDestination,
        onRestore: @escaping (UUID) -> Void
    ) {
        self.destination = destination
        itemCount = items.count

        guard !items.isEmpty, destination != .paletteOnly else {
            hide()
            return
        }

        if destination.usesCompactIconLayout {
            panel.contentView = WorkspaceFloatingDockMinimizedPillView(
                items: items,
                onRestore: onRestore
            )
        } else {
            panel.contentView = WorkspaceFloatingDockMinimizedShelfHostingView(
                rootView: AnyView(WorkspaceFloatingDockMinimizedShelfView(
                    items: items,
                    destination: destination,
                    onRestore: onRestore
                ))
            )
        }
        applyGlassBackdrop()
        reposition()

        guard let parentWindow else { return }
        if panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func teardown() {
        hide()
        glassEffect.remove(from: panel)
        panel.contentView = nil
    }

    func animationSourceFrame() -> CGRect? {
        guard let parentWindow else { return nil }
        return WorkspaceFloatingDockMinimizedShelfLayout.animationTargetFrame(
            parentFrame: parentWindow.frame,
            itemCount: itemCount,
            destination: destination
        )
    }

    @objc private func parentFrameDidChange(_ notification: Notification) {
        reposition()
    }

    private func reposition() {
        guard panel.isVisible,
              let parentWindow,
              let frame = WorkspaceFloatingDockMinimizedShelfLayout.frame(
                parentFrame: parentWindow.frame,
                itemCount: itemCount,
                destination: destination
              ) else { return }
        panel.setFrame(frame, display: true)
    }

    private func hide() {
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    private func applyGlassBackdrop() {
        glassEffect.remove(from: panel)
        let appearance = WorkspaceFloatingDockBackdropAppearance.raycast(
            backgroundColor: GhosttyBackgroundTheme.currentColor()
        )
        glassEffect.backgroundOpacity = appearance.opacity
        glassEffect.apply(
            to: panel,
            tintColor: appearance.tintColor,
            style: appearance.liquidGlassStyle ?? .regular
        )
    }
}

private final class WorkspaceFloatingDockMinimizedShelfPanel: NSPanel {
    private weak var trackedFirstMouseButton: NSButton?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard !isKeyWindow else {
            super.sendEvent(event)
            return
        }

        switch event.type {
        case .leftMouseDown:
            guard let button = button(at: event.locationInWindow) else {
                super.sendEvent(event)
                return
            }
            trackedFirstMouseButton = button
        case .leftMouseDragged:
            guard let trackedFirstMouseButton else {
                super.sendEvent(event)
                return
            }
            if button(at: event.locationInWindow) !== trackedFirstMouseButton {
                self.trackedFirstMouseButton = nil
            }
        case .leftMouseUp:
            guard let trackedFirstMouseButton else {
                super.sendEvent(event)
                return
            }
            self.trackedFirstMouseButton = nil
            if button(at: event.locationInWindow) === trackedFirstMouseButton {
                trackedFirstMouseButton.performClick(nil)
            }
        default:
            super.sendEvent(event)
        }
    }

    private func button(at locationInWindow: NSPoint) -> NSButton? {
        guard let contentView else { return nil }
        return contentView.descendants.compactMap { $0 as? NSButton }.first { button in
            button.bounds.contains(button.convert(locationInWindow, from: nil))
        }
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}

private final class WorkspaceFloatingDockMinimizedShelfHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class WorkspaceFloatingDockMinimizedPillView: NSView {
    init(
        items: [WorkspaceFloatingDockMinimizedShelfItem],
        onRestore: @escaping (UUID) -> Void
    ) {
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for item in items {
            let button = WorkspaceFloatingDockMinimizedPillButton(item: item) {
                onRestore(item.id)
            }
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 32),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class WorkspaceFloatingDockMinimizedPillButton: NSButton {
    private let onPress: () -> Void

    init(item: WorkspaceFloatingDockMinimizedShelfItem, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: item.title)
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        target = self
        action = #selector(press(_:))
        toolTip = String(
            format: String(
                localized: "floatingDock.minimizedShelf.restoreHelp",
                defaultValue: "Restore %@"
            ),
            locale: .current,
            item.title
        )
        identifier = NSUserInterfaceItemIdentifier(
            "WorkspaceFloatingDockMinimizedShelfItem.\(item.id.uuidString)"
        )
        setAccessibilityLabel(item.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press(_ sender: Any?) {
        onPress()
    }
}

private struct WorkspaceFloatingDockMinimizedShelfView: View {
    let items: [WorkspaceFloatingDockMinimizedShelfItem]
    let destination: WorkspaceFloatingDockMinimizeDestination
    let onRestore: (UUID) -> Void

    var body: some View {
        Group {
            if destination.usesVerticalLayout {
                ScrollView(.vertical, showsIndicators: items.count > 10) {
                    VStack(spacing: 5) {
                        itemButtons
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: items.count > 4) {
                    HStack(spacing: 6) {
                        itemButtons
                    }
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityIdentifier("WorkspaceFloatingDockMinimizedShelf")
    }

    @ViewBuilder
    private var itemButtons: some View {
        ForEach(items) { item in
            Button {
                onRestore(item.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .medium))
                    if !destination.usesCompactIconLayout {
                        Text(item.title)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, destination.usesCompactIconLayout ? 0 : 10)
                .frame(
                    width: destination.usesCompactIconLayout ? 32 : nil,
                    height: 32
                )
                .frame(
                    maxWidth: destination.usesVerticalLayout ? .infinity : 154,
                    alignment: .leading
                )
                .background(Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(String(
                format: String(
                    localized: "floatingDock.minimizedShelf.restoreHelp",
                    defaultValue: "Restore %@"
                ),
                locale: .current,
                item.title
            ))
            .accessibilityIdentifier("WorkspaceFloatingDockMinimizedShelfItem.\(item.id.uuidString)")
        }
    }
}

#if DEBUG
@MainActor
@Observable
private final class WorkspaceFloatingDockMinimizeDebugModel {
    var destinationRawValue: String {
        didSet {
            defaults.set(destinationRawValue, forKey: WorkspaceFloatingDockMinimizeDebugSettings.destinationKey)
            AppDelegate.shared?.refreshAllWorkspaceFloatingDocks()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destinationRawValue = WorkspaceFloatingDockMinimizeDebugSettings.currentDestination(
            defaults: defaults
        ).rawValue
    }
}

final class WorkspaceFloatingDockMinimizeDebugWindowController: ReleasingWindowController {
    static let shared = WorkspaceFloatingDockMinimizeDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 330),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.floatingDockMinimize.title",
            defaultValue: "Floating Window Minimize Debug"
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.workspaceFloatingDockMinimizeDebug")
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: WorkspaceFloatingDockMinimizeDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private struct WorkspaceFloatingDockMinimizeDebugView: View {
    @State private var settings = WorkspaceFloatingDockMinimizeDebugModel()

    var body: some View {
        @Bindable var settings = settings
        let selection = WorkspaceFloatingDockMinimizeDestination(
            rawValue: settings.destinationRawValue
        ) ?? WorkspaceFloatingDockMinimizeDebugSettings.defaultDestination

        VStack(alignment: .leading, spacing: 14) {
            Text("debug.floatingDockMinimize.heading")
                .cmuxFont(.headline)

            Picker("debug.floatingDockMinimize.picker", selection: $settings.destinationRawValue) {
                ForEach(WorkspaceFloatingDockMinimizeDestination.allCases) { destination in
                    Text(destination.title).tag(destination.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("WorkspaceFloatingDockMinimizeDestinationPicker")

            Text(selection.detail)
                .cmuxFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("debug.floatingDockMinimize.instructions")
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
