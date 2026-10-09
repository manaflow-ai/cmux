import Foundation
import Observation

/// Per-port Share progress, so the port row can show a spinner while its link
/// is being made and a checkmark once it has been copied.
@MainActor
@Observable
public final class CloudPortShareStore {
    public enum Phase: Equatable, Sendable {
        case creating
        case copied(VMPublicationAccessMode)
        /// The link is ready but wasn't copied, because the clipboard changed
        /// while it was being made. Clicking again copies it at once.
        case ready
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

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let shared = CloudPortShareStore()

    public private(set) var phases: [Key: Phase] = [:]
    @ObservationIgnored private var resetTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var operationIDs: [Key: UUID] = [:]
    @ObservationIgnored private let sleep: Sleep

    /// `sleep` times the auto-dismiss of a finished phase (a brief "copied"
    /// note); it is injected so tests don't wait in real time.
    public init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    public func phase(for key: Key) -> Phase? { phases[key] }

    public func isCreating(_ key: Key) -> Bool { phases[key] == .creating }

    /// Starts a new operation and returns its identity. A late completion from
    /// an older operation cannot clear or overwrite a replacement.
    public func beginCreating(_ key: Key) -> UUID? {
        guard phases[key] != .creating else { return nil }
        let id = UUID()
        operationIDs[key] = id
        set(.creating, for: key)
        return id
    }

    /// Shows `phase` on the row; a finished phase clears itself after `holdFor`.
    public func set(_ phase: Phase, for key: Key, holdFor: Duration? = nil) {
        resetTasks[key]?.cancel()
        resetTasks[key] = nil
        phases[key] = phase
        guard let holdFor else { return }
        let sleep = sleep
        resetTasks[key] = Task { @MainActor [weak self] in
            do { try await sleep(holdFor) } catch { return }
            guard let self, self.phases[key] == phase else { return }
            self.phases[key] = nil
            self.resetTasks[key] = nil
        }
    }

    public func clear(_ key: Key) {
        resetTasks[key]?.cancel()
        resetTasks[key] = nil
        phases[key] = nil
        operationIDs[key] = nil
    }

    public func set(_ phase: Phase, for key: Key, operationID: UUID, holdFor: Duration? = nil) {
        guard operationIDs[key] == operationID else { return }
        set(phase, for: key, holdFor: holdFor)
    }

    public func clear(_ key: Key, operationID: UUID) {
        guard operationIDs[key] == operationID else { return }
        clear(key)
    }
}
