import AppKit
import Dispatch
import Observation
import SwiftUI

@main
struct UiLayerHostApp: App {
    @State private var projection = ProjectionModel(arguments: CommandLine.arguments)

    var body: some Scene {
        WindowGroup("cmux UI layer") {
            UiLayerView(projection: projection)
        }
        .defaultSize(width: 1_120, height: 720)
    }
}

@MainActor
@Observable
final class ProjectionModel {
    private(set) var snapshot = ProjectionSnapshot.placeholder
    private(set) var error: String?
    private let source: UiLayerSource
    @ObservationIgnored private var watcher: ProjectionFileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration: UInt64 = 0

    init(arguments: [String]) {
        source = UiLayerSource.parse(arguments: arguments)
        switch source {
        case .snapshot(let url):
            reload()
            // DispatchSource is the platform primitive for reload-on-save.
            watcher = ProjectionFileWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        case .attach(let path):
            attachTask = Task { [weak self] in
                guard let self else { return }
                for await update in LiveProjectionClient(socketPath: path).updates() {
                    guard !Task.isCancelled else { return }
                    switch update {
                    case .snapshot(let snapshot):
                        self.snapshot = snapshot
                        self.error = nil
                    case .failure(let message):
                        // A live projection never falls back to a stale fixture.
                        self.snapshot = .placeholder
                        self.error = "Live projection unavailable: \(message)"
                    }
                }
            }
        case .invalid(let message):
            error = message
        }
    }

    func reload() {
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        guard case .snapshot(let source) = source else { return }
        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = readProjection(source)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.reloadGeneration == generation else { return }
                self.reloadTask = nil
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.error = nil
                case .failure(let message):
                    self.error = "Projection unavailable at \(source.path): \(message)"
                }
            }
        }
    }
}

enum UiLayerSource: Sendable {
    case snapshot(URL)
    case attach(String)
    case invalid(String)

    static func parse(arguments: [String]) -> Self {
        var snapshot: String?
        var attach: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--snapshot" where index + 1 < arguments.count:
                snapshot = arguments[index + 1]
                index += 2
            case "--snapshot":
                return .invalid("--snapshot needs a path")
            case "--attach" where index + 1 < arguments.count:
                attach = arguments[index + 1]
                index += 2
            case "--attach":
                return .invalid("--attach needs a socket path")
            default:
                index += 1
            }
        }
        if let attach, snapshot == nil { return .attach(attach) }
        if attach != nil, snapshot != nil { return .invalid("use exactly one of --attach or --snapshot") }
        if let snapshot { return .snapshot(URL(fileURLWithPath: snapshot)) }
        if let environment = ProcessInfo.processInfo.environment["CMUX_UI_LAYER_SNAPSHOT"], !environment.isEmpty {
            return .snapshot(URL(fileURLWithPath: environment))
        }
        return .snapshot(FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ui-layer.json"))
    }
}


private let maxProjectionBytes = 8 * 1024 * 1024

private enum ProjectionReadError: LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

private func readProjection(_ source: URL) -> Result<ProjectionSnapshot, ProjectionReadError> {
    do {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxProjectionBytes + 1) ?? Data()
        guard data.count <= maxProjectionBytes else { return .failure(.message("snapshot exceeds 8 MiB")) }
        return .success(try JSONDecoder().decode(ProjectionSnapshot.self, from: data))
    } catch {
        return .failure(.message(error.localizedDescription))
    }
}

private final class ProjectionFileWatcher: @unchecked Sendable {
    // All source state and callbacks are confined to the main dispatch queue.
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var fileSource: (any DispatchSourceFileSystemObject)? = nil
    private var directorySource: (any DispatchSourceFileSystemObject)? = nil

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        let directoryDescriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return nil }
        let directory = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        directorySource = directory
        directory.setEventHandler { [weak self] in
            self?.onChange()
            // Re-open after an atomic replacement. If the file is not present
            // yet, the next directory event retries without polling.
            self?.armFileSource()
        }
        directory.setCancelHandler { close(directoryDescriptor) }
        directory.resume()
        armFileSource()
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        let file = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        fileSource = file
        file.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.fileSource?.data ?? []
            self.onChange()
            if events.contains(.rename) || events.contains(.delete) {
                self.armFileSource()
            }
        }
        file.setCancelHandler { close(fileDescriptor) }
        file.resume()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }
}

struct ProjectionSnapshot: Codable, Sendable {
    var capturedAt: String
    var selectedWorkspaceID: String?
    var workspaces: [ProjectionWorkspace]

    static let placeholder = ProjectionSnapshot(
        capturedAt: "no snapshot loaded",
        selectedWorkspaceID: nil,
        workspaces: [ProjectionWorkspace(id: "demo", name: "Projection", tabs: [ProjectionTab(title: "Save a snapshot to begin")])]
    )
}

struct ProjectionWorkspace: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var tabs: [ProjectionTab]
}

struct ProjectionTab: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var unread: Bool

    init(id: String? = nil, title: String, subtitle: String? = nil, unread: Bool = false) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.unread = unread
    }

    enum CodingKeys: String, CodingKey { case id, title, subtitle, unread }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? title
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }
}

struct UiLayerView: View {
    let projection: ProjectionModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                tabBar
                Divider()
                pane
                composer
            }
        }
        .overlay(alignment: .top) {
            if let error = projection.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                    .frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORKSPACES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(projection.snapshot.workspaces) { workspace in
                HStack {
                    Image(systemName: "rectangle.3.group")
                    Text(workspace.name).lineLimit(1)
                    Spacer()
                    if workspace.id == projection.snapshot.selectedWorkspaceID { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                }
                .padding(.vertical, 5).padding(.horizontal, 7)
                .background(workspace.id == projection.snapshot.selectedWorkspaceID ? Color.gray.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
            Text("READ-ONLY PROJECTION").font(.caption2).foregroundStyle(.secondary)
            Text(projection.snapshot.capturedAt).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14).frame(width: 220).background(.windowBackground)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(selectedWorkspace?.tabs ?? []) { tab in
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.caption)
                    Text(tab.title).lineLimit(1)
                    if tab.unread { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Spacer()
            Image(systemName: "plus").padding(8)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedWorkspace?.name ?? "No workspace").font(.title3.weight(.medium))
            Text("Projection host · terminal and chat content stays read-only")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var composer: some View {
        HStack {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            Text("Composer preview (disabled)").foregroundStyle(.tertiary)
            Spacer()
            Image(systemName: "arrow.up.circle").foregroundStyle(.tertiary)
        }.padding(12).background(.bar)
    }

    private var selectedWorkspace: ProjectionWorkspace? {
        projection.snapshot.workspaces.first { $0.id == projection.snapshot.selectedWorkspaceID }
            ?? projection.snapshot.workspaces.first
    }
}
