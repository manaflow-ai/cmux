public import Foundation
public import Observation

/// Projects: the folders the user's coding agents worked in, found from
/// their session files, ready to open as workspaces. The best few are
/// checked already, so Continue alone does the sensible thing. A folder
/// picker shows only when nothing was found.
@MainActor
@Observable
public final class ProjectsStepModel {
    /// How many projects start checked.
    static let preselected = 5
    /// How many rows the step lists.
    static let listed = 12

    public private(set) var projects: [AgentProject] = []
    public private(set) var selected: Set<String> = []
    public private(set) var isScanning = false
    /// Whether a scan finished (an empty list then means nothing was found).
    public private(set) var scanned = false
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Folders already opened, so Continue after Back opens only new ones.
    @ObservationIgnored private var opened: Set<String> = []
    @ObservationIgnored private var choosing = false

    init(services: any OnboardingServices) {
        self.services = services
    }

    /// Starts the scan once; the role step starts it early so the list is ready.
    public func scan() {
        guard task == nil else { return }
        isScanning = true
        task = Task { [weak self, services] in
            let found = await services.scanAgentProjects()
            guard let self, !Task.isCancelled else { return }
            // Folders added during the scan stay first and checked.
            let best = found.prefix(Self.listed).filter { project in !projects.contains { $0.id == project.id } }
            projects += best
            selected.formUnion(best.prefix(Self.preselected).map(\.id))
            isScanning = false
            scanned = true
        }
    }

    public func isSelected(_ project: AgentProject) -> Bool { selected.contains(project.id) }

    public func toggle(_ project: AgentProject) {
        if selected.contains(project.id) { selected.remove(project.id) } else { selected.insert(project.id) }
    }

    /// A folder the user chose or dropped: listed first and checked.
    public func add(_ folder: URL) {
        let folder = folder.standardizedFileURL
        if !projects.contains(where: { $0.id == folder.path }) {
            projects.insert(AgentProject(folder: folder, sessions: 0, lastActive: Date(), apps: []), at: 0)
        }
        selected.insert(folder.path)
    }

    /// The folder picker (shown when nothing was found).
    public func chooseFolder() {
        guard !choosing else { return }
        choosing = true
        Task { [weak self, services] in
            let folder = await services.chooseFolder()
            self?.choosing = false
            if let folder { self?.add(folder) }
        }
    }

    public var homeDirectory: URL { services.homeDirectory }

    /// The checked folders, in list order.
    public var chosen: [URL] { projects.filter { selected.contains($0.id) }.map(\.folder) }

    /// The privacy-guarded folders among the checked ones, in a fixed
    /// order: macOS asks once for each, all at Continue.
    public var privacyFolders: [PrivacyFolder] {
        let scan = AgentProjectScan(home: homeDirectory)
        let found = Set(chosen.compactMap(scan.privacyFolder(of:)))
        return PrivacyFolder.allCases.filter(found.contains)
    }

    /// Continue: opens the checked folders as workspaces, each once.
    func commit() {
        let folders = chosen.filter { !opened.contains($0.path) }
        guard !folders.isEmpty else { return }
        opened.formUnion(folders.map(\.path))
        services.openProjects(folders)
    }

    func stop() {
        task?.cancel()
    }
}
