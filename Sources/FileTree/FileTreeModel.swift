import Foundation
import SwiftUI

@MainActor
final class FileTreeModel: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileTreeNode] = []
    @Published var showHiddenFiles: Bool = true

    private var fsEventStream: FSEventStreamRef?
    private var refreshCoalesceTask: Task<Void, Never>?

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func loadDirectory(_ path: String) {
        rootPath = path
        Task {
            let nodes = await scanDirectory(path)
            self.rootNodes = nodes
        }
        startWatching(path: path)
    }

    func toggleExpand(_ node: FileTreeNode) {
        guard node.isDirectory else { return }
        var updated = rootNodes
        let _ = findAndUpdate(in: &updated, id: node.id) { n in
            n.isExpanded.toggle()
            if n.isExpanded && n.children == nil {
                n.children = []
                let path = n.path
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let children = await self.scanDirectory(path)
                    var current = self.rootNodes
                    let _ = self.findAndUpdate(in: &current, id: node.id) { n in
                        n.children = children
                    }
                    self.rootNodes = current
                }
            }
        }
        rootNodes = updated
    }

    func refresh() {
        guard !rootPath.isEmpty else { return }
        let expandedIds = collectExpandedIds(rootNodes)
        Task {
            let nodes = await scanDirectory(rootPath)
            var result = nodes
            restoreExpandedState(in: &result, expandedIds: expandedIds)
            self.rootNodes = result
        }
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        refresh()
    }

    // MARK: - FSEvents Watching

    private func startWatching(path: String) {
        stopWatching()

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let paths = [path] as CFArray
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 500ms latency for coalescing rapid changes
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopWatching() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    fileprivate func handleFSEvent() {
        // Coalesce rapid events into a single refresh
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled, let self else { return }
            self.refresh()
        }
    }

    // MARK: - Private

    private func scanDirectory(_ path: String) async -> [FileTreeNode] {
        let showHidden = showHiddenFiles
        return await Task.detached {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
                return [FileTreeNode]()
            }

            var nodes: [FileTreeNode] = []
            for name in contents {
                let isHidden = name.hasPrefix(".")
                if isHidden && !showHidden { continue }

                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                nodes.append(FileTreeNode(
                    id: fullPath,
                    name: name,
                    path: fullPath,
                    isDirectory: isDir.boolValue,
                    isHidden: isHidden,
                    children: isDir.boolValue ? nil : []
                ))
            }

            nodes.sort { a, b in
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            return nodes
        }.value
    }

    @discardableResult
    private func findAndUpdate(
        in nodes: inout [FileTreeNode],
        id: String,
        transform: (inout FileTreeNode) -> Void
    ) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id {
                transform(&nodes[i])
                return true
            }
            if var children = nodes[i].children {
                if findAndUpdate(in: &children, id: id, transform: transform) {
                    nodes[i].children = children
                    return true
                }
            }
        }
        return false
    }

    private func collectExpandedIds(_ nodes: [FileTreeNode]) -> Set<String> {
        var ids = Set<String>()
        for node in nodes {
            if node.isExpanded {
                ids.insert(node.id)
            }
            if let children = node.children {
                ids.formUnion(collectExpandedIds(children))
            }
        }
        return ids
    }

    private func restoreExpandedState(in nodes: inout [FileTreeNode], expandedIds: Set<String>) {
        for i in nodes.indices {
            if expandedIds.contains(nodes[i].id) && nodes[i].isDirectory {
                nodes[i].isExpanded = true
                if nodes[i].children == nil {
                    let path = nodes[i].path
                    let nodeId = nodes[i].id
                    nodes[i].children = []
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let children = await self.scanDirectory(path)
                        var current = self.rootNodes
                        let _ = self.findAndUpdate(in: &current, id: nodeId) { n in
                            n.children = children
                        }
                        self.rootNodes = current
                    }
                }
            }
            if var children = nodes[i].children {
                restoreExpandedState(in: &children, expandedIds: expandedIds)
                nodes[i].children = children
            }
        }
    }
}

// FSEvents callback must be a C function pointer, so it's outside the class
private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let model = Unmanaged<FileTreeModel>.fromOpaque(info).takeUnretainedValue()
    Task { @MainActor in
        model.handleFSEvent()
    }
}
