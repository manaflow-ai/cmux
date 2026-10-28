import AppKit
import CmuxNextDesign
import CmuxNextFiles
import CmuxNextWakeups

/// A Get Info window (Cmd+I) for one item, as Finder opens one per item:
/// icon and name, Kind, Size (folders add up in the background), Where,
/// dates, owner and permissions, and the Locked and Hide extension boxes.
@MainActor
final class FileInfoWindow: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let url: URL
    private let reader: FileInfoReader
    /// The app's main-thread scheduler: the reads off main fill the window as posted tasks on it.
    private let mainWork: MainWorkScheduler
    private let grid = NSGridView()
    private let locked = NSButton(checkboxWithTitle: FilesStrings.infoLocked, target: nil, action: nil)
    private let hideExtension = NSButton(checkboxWithTitle: FilesStrings.infoHideExtension, target: nil, action: nil)
    private var loading: Task<Void, Never>?
    private var onClose: (() -> Void)?
    private let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    /// Makes the window for `url`; `icons` gives its icon (now when kept, else from the system lane); `mainWork`
    /// runs its fills; `reader` reads its facts on the app's lanes; `onClose` runs when it closes.
    init(url: URL, icons: FileIconProvider, mainWork: MainWorkScheduler, reader: FileInfoReader,
         onClose: @escaping () -> Void) {
        self.url = url
        self.reader = reader
        self.mainWork = mainWork
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        super.init()
        panel.title = FilesStrings.infoTitle(url.lastPathComponent)
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false  // AppKit state restoration is off for every cmux window
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let image = NSImageView(image: NSImage(systemSymbolName: url.hasDirectoryPath ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage())
        icons.fileIcon(at: url) { [weak image] in image?.image = $0 }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 48).isActive = true
        image.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(wrappingLabelWithString: url.lastPathComponent)
        name.font = Typography.system(size: TypeScale.body, weight: .semibold)
        let header = NSStackView(views: [image, name])
        header.spacing = Metrics.space2
        grid.rowSpacing = 4
        grid.columnSpacing = Metrics.space2
        locked.target = self
        locked.action = #selector(lockedChanged)
        hideExtension.target = self
        hideExtension.action = #selector(hideExtensionChanged)
        let stack = NSStackView(views: [header, grid, locked, hideExtension])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = stack
        load()
    }

    /// Shows the window near the others (cascaded).
    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Reads the item off main, then fills the window: the first fill is the rest of the person's Get Info
    /// (userBlocking), a folder's size follows when it is added up (visible).
    private func load() {
        let show: @MainActor @Sendable (FileInfo, FolderSize?) -> Void = { [weak self] info, size in
            self?.fill(info, folderSize: size)
        }
        let url = url, reader = reader, mainWork = mainWork
        // task-owner: the window's reads off main; cancelled when it closes
        loading = Task { @concurrent in
            guard let info = try? await reader.info(for: url) else { return }
            mainWork.postFromAnyThread(.userBlocking, owner: "FileInfo.fill") { show(info, nil) }
            guard info.fileKind == .folder || info.fileKind == .package else { return }
            let size = await reader.folderSize(of: url)
            guard !Task.isCancelled else { return }
            mainWork.postFromAnyThread(.visible, owner: "FileInfo.folderSize") { show(info, size) }
        }
    }

    private func fill(_ info: FileInfo, folderSize: FolderSize?) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        let sizeText: String
        if let size = info.size {
            sizeText = FilesStrings.infoBytes(bytes.string(fromByteCount: size), size)
        } else if let folderSize {
            sizeText = FilesStrings.infoFolderSize(bytes.string(fromByteCount: folderSize.bytes), folderSize.items)
        } else {
            sizeText = FilesStrings.infoCalculating
        }
        var rows: [(String, String)] = [
            (FilesStrings.infoKind, info.kind),
            (FilesStrings.infoSize, sizeText),
            (FilesStrings.infoWhere, info.folder.path),
        ]
        if let created = info.created { rows.append((FilesStrings.infoCreated, dates.string(from: created))) }
        if let modified = info.modified { rows.append((FilesStrings.infoModified, dates.string(from: modified))) }
        if let opened = info.lastOpened { rows.append((FilesStrings.infoOpened, dates.string(from: opened))) }
        if let owner = info.owner { rows.append((FilesStrings.infoOwner, owner)) }
        rows.append((FilesStrings.infoPermissions, Self.permissionText(info.permissions)))
        for (title, value) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = Typography.system(size: TypeScale.caption, weight: .semibold)
            label.alignment = .right
            let text = NSTextField(wrappingLabelWithString: value)
            text.font = Typography.system(size: TypeScale.caption)
            text.isSelectable = true
            text.focusRingType = .none
            text.preferredMaxLayoutWidth = 200
            grid.addRow(with: [label, text])
        }
        locked.state = info.isLocked ? .on : .off
        hideExtension.state = info.isExtensionHidden ? .on : .off
        hideExtension.isEnabled = !info.url.pathExtension.isEmpty
    }

    /// `rwxr-xr-x` style text plus the octal mode.
    private static func permissionText(_ mode: Int) -> String {
        let marks: [Character] = ["r", "w", "x"]
        let text = (0..<9).map { bit in mode & (1 << (8 - bit)) != 0 ? String(marks[bit % 3]) : "-" }.joined()
        return text + " (" + String(mode & 0o7777, radix: 8) + ")"
    }

    @objc private func lockedChanged() {
        let on = locked.state == .on
        // task-owner: one attribute write off main; the box already shows the person's choice
        Task { @concurrent [reader, url] in try? await reader.setLocked(on, for: url) }
    }

    @objc private func hideExtensionChanged() {
        let on = hideExtension.state == .on
        // task-owner: one attribute write off main; the box already shows the person's choice
        Task { @concurrent [reader, url] in try? await reader.setExtensionHidden(on, for: url) }
    }

    func windowWillClose(_ notification: Notification) {
        loading?.cancel()
        onClose?()
        onClose = nil
    }
}
