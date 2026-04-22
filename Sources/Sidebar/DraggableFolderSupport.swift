import AppKit
import Bonsplit
import SwiftUI

struct DraggableFolderIcon: View {
    let directory: String

    var body: some View {
        DraggableFolderIconRepresentable(directory: directory)
            .frame(width: 16, height: 16)
            .safeHelp(String(localized: "sidebar.folderIcon.dragHint", defaultValue: "Drag to open in Finder or another app"))
            .onTapGesture(count: 2) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory)
            }
    }
}

private struct DraggableFolderIconRepresentable: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ nsView: DraggableFolderNSView, context: Context) {
        nsView.directory = directory
        nsView.updateIcon()
    }
}

final class DraggableFolderNSView: NSView, NSDraggingSource {
    private final class FolderIconImageView: NSImageView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    var directory: String
    private var imageView: FolderIconImageView!
    private var previousWindowMovableState: Bool?
    private weak var suppressedWindow: NSWindow?
    private var hasActiveDragSession = false
    private var didArmWindowDragSuppression = false

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
        updateIcon()
    }

    func updateIcon() {
        let icon = NSWorkspace.shared.icon(forFile: directory)
        icon.size = NSSize(width: 16, height: 16)
        imageView.image = icon
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasActiveDragSession = false
        restoreWindowMovableStateIfNeeded()
        #if DEBUG
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.dragEnd dir=\(directory) operation=\(operation.rawValue) screen=\(formatPoint(screenPoint)) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let hit = super.hitTest(point)
        #if DEBUG
        let hitDesc = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let imageHit = (hit === imageView)
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        dlog("folder.hitTest point=\(formatPoint(point)) hit=\(hitDesc) imageViewHit=\(imageHit) returning=DraggableFolderNSView wasMovable=\(wasMovable) nowMovable=\(nowMovable)")
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        maybeDisableWindowDraggingEarly(trigger: "mouseDown")
        hasActiveDragSession = false
        #if DEBUG
        let localPoint = convert(event.locationInWindow, from: nil)
        let responderDesc = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = window.map { String($0.isMovable) } ?? "nil"
        let windowOrigin = window.map { formatPoint($0.frame.origin) } ?? "nil"
        dlog("folder.mouseDown dir=\(directory) point=\(formatPoint(localPoint)) firstResponder=\(responderDesc) wasMovable=\(wasMovable) nowMovable=\(nowMovable) windowOrigin=\(windowOrigin)")
        #endif
        let fileURL = URL(fileURLWithPath: directory)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)

        let iconImage = NSWorkspace.shared.icon(forFile: directory)
        iconImage.size = NSSize(width: 32, height: 32)
        draggingItem.setDraggingFrame(bounds, contents: iconImage)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        hasActiveDragSession = true
        #if DEBUG
        let itemCount = session.draggingPasteboard.pasteboardItems?.count ?? 0
        dlog("folder.dragStart dir=\(directory) pasteboardItems=\(itemCount)")
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Always restore suppression on mouse-up; drag-session callbacks can be
        // skipped for non-started drags, which would otherwise leave suppression stuck.
        restoreWindowMovableStateIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
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

        // Add path components (current dir at top, root at bottom, matching native macOS)
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
        // Open "Computer" view in Finder, which shows all volumes.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/", isDirectory: true))
    }

    private func restoreWindowMovableStateIfNeeded() {
        guard didArmWindowDragSuppression || previousWindowMovableState != nil else { return }
        let targetWindow = suppressedWindow ?? window
        let depthAfter = endWindowDragSuppression(window: targetWindow)
        restoreWindowDragging(window: targetWindow, previousMovableState: previousWindowMovableState)
        self.previousWindowMovableState = nil
        self.suppressedWindow = nil
        self.didArmWindowDragSuppression = false
        #if DEBUG
        let nowMovable = targetWindow.map { String($0.isMovable) } ?? "nil"
        dlog("folder.dragSuppression restore depth=\(depthAfter) nowMovable=\(nowMovable)")
        #endif
    }

    private func maybeDisableWindowDraggingEarly(trigger: String) {
        guard !didArmWindowDragSuppression else { return }
        guard let eventType = NSApp.currentEvent?.type,
              eventType == .leftMouseDown || eventType == .leftMouseDragged else {
            return
        }
        guard let currentWindow = window else { return }

        didArmWindowDragSuppression = true
        suppressedWindow = currentWindow
        let suppressionDepth = beginWindowDragSuppression(window: currentWindow) ?? 0
        if currentWindow.isMovable {
            previousWindowMovableState = temporarilyDisableWindowDragging(window: currentWindow)
        } else {
            previousWindowMovableState = nil
        }
        #if DEBUG
        let wasMovable = previousWindowMovableState.map(String.init) ?? "nil"
        let nowMovable = String(currentWindow.isMovable)
        dlog(
            "folder.dragSuppression trigger=\(trigger) event=\(eventType) depth=\(suppressionDepth) wasMovable=\(wasMovable) nowMovable=\(nowMovable)"
        )
        #endif
    }
}

func temporarilyDisableWindowDragging(window: NSWindow?) -> Bool? {
    guard let window else { return nil }
    let wasMovable = window.isMovable
    if wasMovable {
        window.isMovable = false
    }
    return wasMovable
}

func restoreWindowDragging(window: NSWindow?, previousMovableState: Bool?) {
    guard let window, let previousMovableState else { return }
    window.isMovable = previousMovableState
}
