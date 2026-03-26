import Foundation
import Combine

/// UserDefaults keys for file explorer persistence.
enum FileExplorerDefaults {
    static let isVisibleKey = "cmux.fileExplorer.isVisible"
    static let dividerPositionKey = "cmux.fileExplorer.dividerPosition"
    static let showHiddenKey = "cmux.fileExplorer.showHidden"
}

/// Manages the file explorer tree state for a single workspace.
@MainActor
final class FileExplorerState: ObservableObject {
    /// Root directory URL (workspace's current working directory).
    @Published private(set) var rootURL: URL?

    /// The top-level nodes of the file tree.
    @Published private(set) var rootNodes: [FileExplorerNode] = []

    /// Whether hidden files are shown.
    @Published var showHidden: Bool {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: FileExplorerDefaults.showHiddenKey)
            if oldValue != showHidden, let rootURL {
                reload(at: rootURL)
            }
        }
    }

    /// Whether the file explorer section is visible in the sidebar.
    @Published var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: FileExplorerDefaults.isVisibleKey)
        }
    }

    /// Proportion of sidebar allocated to the tab list (0.0–1.0).
    /// The file explorer gets `1 - dividerPosition`.
    @Published var dividerPosition: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(dividerPosition), forKey: FileExplorerDefaults.dividerPositionKey)
        }
    }

    // MARK: - File watching

    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let watchQueue = DispatchQueue(label: "com.cmux.file-explorer-watch", qos: .utility)

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        self.isVisible = defaults.bool(forKey: FileExplorerDefaults.isVisibleKey)
        self.showHidden = defaults.bool(forKey: FileExplorerDefaults.showHiddenKey)
        let storedPosition = defaults.double(forKey: FileExplorerDefaults.dividerPositionKey)
        self.dividerPosition = storedPosition > 0 ? CGFloat(storedPosition) : 0.6
    }

    // MARK: - Public API

    /// Set the root directory and load the initial tree.
    func setRoot(_ url: URL?) {
        guard url != rootURL else { return }
        rootURL = url
        stopWatching()
        if let url {
            reload(at: url)
            startWatching(url)
        } else {
            rootNodes = []
        }
    }

    /// Toggle a directory node's expanded state and lazy-load children.
    func toggleExpanded(nodeId: String) {
        guard let rootURL else { return }
        toggleExpandedInPlace(nodeId: nodeId, nodes: &rootNodes, root: rootURL)
    }

    /// Refresh the entire tree from disk.
    func refresh() {
        guard let rootURL else { return }
        reload(at: rootURL)
    }

    // MARK: - Tree mutation

    private func reload(at url: URL) {
        rootNodes = FileExplorerNode.scanDirectory(at: url, relativeTo: url, showHidden: showHidden)
    }

    private func toggleExpandedInPlace(
        nodeId: String,
        nodes: inout [FileExplorerNode],
        root: URL
    ) {
        for index in nodes.indices {
            if nodes[index].id == nodeId {
                nodes[index].isExpanded.toggle()
                if nodes[index].isExpanded && nodes[index].children == nil {
                    // Lazy load children on first expand
                    nodes[index].children = FileExplorerNode.scanDirectory(
                        at: nodes[index].url,
                        relativeTo: root,
                        showHidden: showHidden
                    )
                }
                return
            }
            // Recurse into expanded directories
            if nodes[index].isDirectory, nodes[index].isExpanded, nodes[index].children != nil {
                toggleExpandedInPlace(nodeId: nodeId, nodes: &nodes[index].children!, root: root)
            }
        }
    }

    // MARK: - File system watching

    private func startWatching(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        source.setCancelHandler { [fd] in
            close(fd)
        }

        fileWatchSource = source
        source.resume()
    }

    private func stopWatching() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        fileDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
    }
}
