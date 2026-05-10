import AppKit
import SwiftUI

struct DetachedFolderDragIcon: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DetachedFolderDragIconHostView {
        DetachedFolderDragIconHostView(directory: directory)
    }

    func updateNSView(_ nsView: DetachedFolderDragIconHostView, context: Context) {
        nsView.directory = directory
        nsView.syncDetachedIcon()
    }
}

@MainActor
final class DetachedFolderDragIconHostView: NSView {
    var directory: String
    private var childWindow: NSPanel?
    private var iconView: DraggableFolderNSView?
    private var observers: [NSObjectProtocol] = []
    private weak var observedParentWindow: NSWindow?

    init(directory: String) {
        self.directory = directory
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 16, height: 16)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            tearDownDetachedIcon()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDetachedIcon()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncDetachedIcon()
    }

    override func layout() {
        super.layout()
        syncDetachedIconFrame()
    }

    func syncDetachedIcon() {
        guard let parentWindow = window else {
            tearDownDetachedIcon()
            return
        }

        let child = childWindow ?? makeDetachedIconWindow(parentWindow: parentWindow)
        if child.parent !== parentWindow {
            child.parent?.removeChildWindow(child)
            parentWindow.addChildWindow(child, ordered: .above)
            installParentWindowObservers(parentWindow)
        }

        if iconView?.directory != directory {
            iconView?.directory = directory
            iconView?.updateIcon()
        }

        child.orderFront(nil)
        syncDetachedIconFrame()
    }

    private func makeDetachedIconWindow(parentWindow: NSWindow) -> NSPanel {
        let iconView = DraggableFolderNSView(directory: directory)
        iconView.frame = NSRect(origin: .zero, size: NSSize(width: 16, height: 16))

        let panel = NSPanel(
            contentRect: iconView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = iconView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.folderDragIcon")
        parentWindow.addChildWindow(panel, ordered: .above)
        self.childWindow = panel
        self.iconView = iconView
        installParentWindowObservers(parentWindow)
        return panel
    }

    private func installParentWindowObservers(_ parentWindow: NSWindow) {
        guard observedParentWindow !== parentWindow || observers.isEmpty else { return }
        removeParentWindowObservers()

        // The child panel frame is derived from this host view in the parent
        // window. AppKit does not call layout() when only the parent window
        // moves, resizes, or changes miniaturized state, so observe those
        // window events and recompute the panel's screen-space frame.
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: parentWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncDetachedIconFrame()
                }
            }
        }
        observedParentWindow = parentWindow
    }

    private func syncDetachedIconFrame() {
        guard let parentWindow = window,
              let childWindow else { return }
        let localRect = bounds.isEmpty
            ? NSRect(origin: .zero, size: NSSize(width: 16, height: 16))
            : bounds
        let rectInWindow = convert(localRect, to: nil)
        let rectOnScreen = parentWindow.convertToScreen(rectInWindow)
        if childWindow.frame.origin != rectOnScreen.origin || childWindow.frame.size != rectOnScreen.size {
            childWindow.setFrame(rectOnScreen, display: true)
        }
    }

    private func removeParentWindowObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        observedParentWindow = nil
    }

    private func tearDownDetachedIcon() {
        // Observer lifetime is tied to the derived child panel: once this host
        // leaves its parent window or deinitializes, remove both so no stale
        // panel keeps tracking an old parent window.
        removeParentWindowObservers()
        if let childWindow {
            childWindow.parent?.removeChildWindow(childWindow)
            childWindow.orderOut(nil)
        }
        childWindow = nil
        iconView = nil
    }
}

@MainActor
final class DraggableFolderNSView: NSView, NSDraggingSource {
    private final class FolderIconImageView: NSImageView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    var directory: String
    private var imageView: FolderIconImageView!
    private var pendingDragEvent: NSEvent?
    private var pendingDragStartPoint: NSPoint?
    private let dragStartThresholdSquared: CGFloat = 9

    private func formatPoint(_ point: NSPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setupImageView() {
        imageView = FolderIconImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        let dragHint = String(localized: "sidebar.folderIcon.dragHint", defaultValue: "Drag to open in Finder or another app")
        toolTip = dragHint
        imageView.toolTip = dragHint
        updateIcon()
    }

    func updateIcon() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        let icon = NSWorkspace.shared.icon(forFile: directory)
        icon.size = NSSize(width: 16, height: 16)
        imageView.image = icon
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        #if DEBUG
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        cmuxDebugLog("folder.dragEnd dirBytes=\(directory.utf8.count) operation=\(operation.rawValue) screen=\(formatPoint(screenPoint)) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let hit = super.hitTest(point)
        #if DEBUG
        let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let imageHit = (hit === imageView)
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        cmuxDebugLog("folder.hitTest point=\(formatPoint(point)) hit=\(hitDesc) imageViewHit=\(imageHit) returning=DraggableFolderNSView nowMovable=\(nowMovable)")
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            clearPendingDrag()
            showPathMenu()
            return
        }

        if event.clickCount == 2 {
            clearPendingDrag()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
            return
        }

        #if DEBUG
        let localPoint = convert(event.locationInWindow, from: nil)
        let responderDesc = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        cmuxDebugLog("folder.mouseDown dirBytes=\(directory.utf8.count) point=\(formatPoint(localPoint)) firstResponder=\(responderDesc) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif

        pendingDragEvent = event
        pendingDragStartPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint = pendingDragStartPoint else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let deltaX = currentPoint.x - dragStartPoint.x
        let deltaY = currentPoint.y - dragStartPoint.y
        guard (deltaX * deltaX) + (deltaY * deltaY) >= dragStartThresholdSquared else { return }

        let dragEvent = pendingDragEvent ?? event
        clearPendingDrag()
        beginFolderDrag(with: dragEvent)
    }

    override func mouseUp(with event: NSEvent) {
        clearPendingDrag()
        super.mouseUp(with: event)
    }

    private func clearPendingDrag() {
        pendingDragEvent = nil
        pendingDragStartPoint = nil
    }

    private func beginFolderDrag(with event: NSEvent) {
        let fileURL = URL(fileURLWithPath: directory)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)

        let iconImage = NSWorkspace.shared.icon(forFile: directory)
        iconImage.size = NSSize(width: 32, height: 32)
        draggingItem.setDraggingFrame(bounds, contents: iconImage)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        #if DEBUG
        let itemCount = session.draggingPasteboard.pasteboardItems?.count ?? 0
        cmuxDebugLog("folder.dragStart dirBytes=\(directory.utf8.count) pasteboardItems=\(itemCount)")
        #endif
    }

    override func rightMouseDown(with event: NSEvent) {
        clearPendingDrag()
        showPathMenu()
    }

    private func showPathMenu() {
        let menu = buildPathMenu()
        // Pop up menu at bottom-left of icon (like native proxy icon)
        let menuLocation = NSPoint(x: 0, y: bounds.height)
        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func buildPathMenu() -> NSMenu {
        let menu = NSMenu()
        let url = URL(fileURLWithPath: directory).standardized
        var pathComponents: [URL] = []

        // Build path from current directory up to root
        var current = url
        while current.path != "/" {
            pathComponents.append(current)
            current = current.deletingLastPathComponent()
        }
        pathComponents.append(URL(fileURLWithPath: "/"))

        // Add path components (current dir at top, root at bottom - matches native macOS)
        for pathURL in pathComponents {
            let icon = NSWorkspace.shared.icon(forFile: pathURL.path)
            icon.size = NSSize(width: 16, height: 16)

            let displayName: String
            if pathURL.path == "/" {
                // Use the volume name for root
                if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
                    displayName = volumeName
                } else {
                    displayName = String(localized: "sidebar.pathMenu.macintoshHD", defaultValue: "Macintosh HD")
                }
            } else {
                displayName = FileManager.default.displayName(atPath: pathURL.path)
            }

            let item = NSMenuItem(title: displayName, action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.image = icon
            item.representedObject = pathURL
            menu.addItem(item)
        }

        // Add computer name at the bottom (like native proxy icon)
        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let computerIcon = NSImage(named: NSImage.computerName) ?? NSImage()
        computerIcon.size = NSSize(width: 16, height: 16)

        let computerItem = NSMenuItem(title: computerName, action: #selector(openComputer(_:)), keyEquivalent: "")
        computerItem.target = self
        computerItem.image = computerIcon
        menu.addItem(computerItem)

        return menu
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func openComputer(_ sender: NSMenuItem) {
        // Open the root filesystem entry represented by the bottom path item.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/", isDirectory: true))
    }
}
