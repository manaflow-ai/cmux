import Combine
import Foundation

/// Per-port Share progress, so the port row can show a spinner while its link
/// is being made and a checkmark once it has been copied.
@MainActor
public final class CloudPortShareStore: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case creating
        case copied(VMPublicationAccessMode)
        case failed
    }

    public struct Key: Hashable, Sendable {
        public let machineID: String
        public let port: Int
        public init(machineID: String, port: Int) {
            self.machineID = machineID
            self.port = port
        }
    }

    public static let shared = CloudPortShareStore()

    @Published public private(set) var phases: [Key: Phase] = [:]
    private var resetTasks: [Key: Task<Void, Never>] = [:]

    public init() {}

    public func phase(for key: Key) -> Phase? { phases[key] }

    public func isCreating(_ key: Key) -> Bool { phases[key] == .creating }

    /// Shows `phase` on the row; a finished phase clears itself after `holdFor`.
    public func set(_ phase: Phase, for key: Key, holdFor: Duration? = nil) {
        resetTasks[key]?.cancel()
        resetTasks[key] = nil
        phases[key] = phase
        guard let holdFor else { return }
        resetTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: holdFor)
            guard !Task.isCancelled, let self, self.phases[key] == phase else { return }
            self.phases[key] = nil
            self.resetTasks[key] = nil
        }
    }

    public func clear(_ key: Key) {
        resetTasks[key]?.cancel()
        resetTasks[key] = nil
        phases[key] = nil
    }
}
