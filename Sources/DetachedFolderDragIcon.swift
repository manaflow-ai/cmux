import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DetachedFolderDragIcon: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ nsView: DraggableFolderNSView, context: Context) {
        if nsView.directory != directory {
            nsView.directory = directory
            nsView.updateIcon()
        }
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
        identifier = NSUserInterfaceItemIdentifier("cmux.folderDragIcon")
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

    private static let displayNameLookups = DetachedFolderPathLookupCache<String>()

    /// UTType-based generic folder icon. Avoid `icon(forFile:)`: it stats the
    /// path, and remote tmux directories can block on the autofs automounter.
    private static func genericFolderIcon(size: CGFloat) -> NSImage {
        let generic = (NSWorkspace.shared.icon(for: .folder).copy() as? NSImage) ?? NSWorkspace.shared.icon(for: .folder)
        generic.size = NSSize(width: size, height: size)
        return generic
    }

    /// Resolves the localized display name for `path` off-main (the API
    /// stats), then runs `onResolved` on the main thread.
    private static func localizedDisplayName(forPath path: String, onResolved: @escaping (String) -> Void) {
        if let cached = displayNameLookups.value(forPath: path) {
            onResolved(cached)
            return
        }
        guard displayNameLookups.enqueueCallback(forPath: path, callback: onResolved) else { return }
        Task.detached(priority: .userInitiated) {
            let localizedName = FileManager.default.displayName(atPath: path)
            await MainActor.run {
                displayNameLookups.resolve(path: path, value: localizedName)
            }
        }
    }

    func updateIcon() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        imageView.image = Self.genericFolderIcon(size: 16)
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

        // Cosmetic drag image: use the generic folder rather than re-statting
        // `directory` — see updateIcon().
        let iconImage = Self.genericFolderIcon(size: 32)
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
            let path = pathURL.path
            let displayName: String
            if path == "/" {
                // Use the volume name for root ("/" is always local — safe to stat)
                if let volumeName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
                    displayName = volumeName
                } else {
                    displayName = String(localized: "sidebar.pathMenu.macintoshHD", defaultValue: "Macintosh HD")
                }
            } else {
                // Placeholder; the localized display name comes from a stat'ing
                // API and is refined off-main below.
                displayName = (path as NSString).lastPathComponent
            }

            let item = NSMenuItem(title: displayName, action: #selector(openPathComponent(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.genericFolderIcon(size: 16)
            item.representedObject = pathURL
            if path != "/" {
                Self.localizedDisplayName(forPath: path) { [weak item] localizedName in
                    item?.title = localizedName
                }
            }
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
