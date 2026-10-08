public import Foundation
public import Observation

/// The classic cmux session import step. Workspaces are checked by default because
/// importing topology is reversible and does not execute saved commands.
@MainActor
@Observable
public final class ClassicSessionsStepModel {
    public private(set) var workspaces: [ClassicSessionWorkspace] = []
    public private(set) var selected: Set<String> = []
    public private(set) var isScanning = false
    public private(set) var scanned = false
    /// A snapshot read failure keeps this step visible so the user can see
    /// that the classic session could not be imported.
    public private(set) var scanError: String?
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var imported: Set<String> = []

    init(services: any OnboardingServices) { self.services = services }

    public func scan() {
        guard task == nil else { return }
        isScanning = true
        task = Task { [weak self, services] in
            let found: [ClassicSessionWorkspace]
            do {
                found = try await services.scanClassicSessions()
            } catch {
                guard let self, !Task.isCancelled else { return }
                scanError = error.localizedDescription
                workspaces = []
                selected = []
                isScanning = false
                scanned = true
                return
            }
            guard let self, !Task.isCancelled else { return }
            scanError = nil
            workspaces = found
            selected = Set(found.map { Self.id($0) })
            isScanning = false
            scanned = true
        }
    }

    public func toggle(_ workspace: ClassicSessionWorkspace) {
        let id = Self.id(workspace)
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    public func isSelected(_ workspace: ClassicSessionWorkspace) -> Bool { selected.contains(Self.id(workspace)) }
    public var chosen: [ClassicSessionWorkspace] { workspaces.filter { selected.contains(Self.id($0)) } }

    func commit() {
        let pending = chosen.filter { !imported.contains(Self.id($0)) }
        guard !pending.isEmpty else { return }
        imported.formUnion(pending.map(Self.id))
        services.importClassicSessions(pending)
    }
    func stop() { task?.cancel() }

    static func id(_ workspace: ClassicSessionWorkspace) -> String { "\(workspace.name)\0\(workspace.workingDirectory)" }
}
