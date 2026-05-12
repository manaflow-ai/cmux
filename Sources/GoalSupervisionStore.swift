import Foundation
import Observation

actor GoalSupervisionPersistence {
    static let live = GoalSupervisionPersistence(fileURL: defaultFileURL())

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [GoalSupervisionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GoalSupervisionRecord].self, from: data)
    }

    func save(_ goals: [GoalSupervisionRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(goals)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("goals.json", isDirectory: false)
    }
}

@MainActor
@Observable
final class GoalSupervisionStore {
    static let shared = GoalSupervisionStore()

    private(set) var goals: [GoalSupervisionRecord] = []
    private(set) var lastError: String?

    @ObservationIgnored private let persistence: GoalSupervisionPersistence
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var mutationRevision: UInt64 = 0

    init(persistence: GoalSupervisionPersistence = .live) {
        self.persistence = persistence
        Task { await load() }
    }

    func snapshots(at date: Date = .now) -> [GoalSupervisionSnapshot] {
        goals.map { goal in
            GoalSupervisionSnapshot(
                id: goal.id,
                title: goal.title,
                acceptanceCriteria: goal.acceptanceCriteria,
                workspacePath: goal.workspacePath,
                status: goal.status,
                createdAt: goal.createdAt,
                updatedAt: goal.updatedAt,
                activeSince: goal.activeSince,
                accumulatedActiveSeconds: goal.accumulatedActiveSeconds,
                notes: goal.notes
            )
        }
    }

    func createGoal(title: String, acceptanceCriteria: String, workspacePath: String?) -> UUID? {
        let normalizedTitle = Self.normalized(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let now = Date.now
        let goal = GoalSupervisionRecord(
            id: UUID(),
            title: normalizedTitle,
            acceptanceCriteria: Self.normalized(acceptanceCriteria),
            workspacePath: Self.normalizedOptional(workspacePath),
            status: .active,
            createdAt: now,
            updatedAt: now,
            activeSince: now,
            accumulatedActiveSeconds: 0,
            notes: []
        )
        goals.insert(goal, at: 0)
        sortGoals()
        recordMutation()
        persistCurrentGoals()
        return goal.id
    }

    func updateStatus(for id: UUID, status: GoalSupervisionStatus) {
        updateGoal(id: id) { goal, now in
            guard goal.status != status else { return false }
            goal.accumulateActiveTime(endingAt: now)
            goal.status = status
            goal.activeSince = status == .active ? now : nil
            return true
        }
    }

    func addNote(to id: UUID, body: String) {
        let normalizedBody = Self.normalized(body)
        guard !normalizedBody.isEmpty else { return }
        updateGoal(id: id) { goal, now in
            goal.notes.insert(
                GoalSupervisionNote(id: UUID(), body: normalizedBody, createdAt: now),
                at: 0
            )
            return true
        }
    }

    func deleteGoal(id: UUID) {
        guard goals.contains(where: { $0.id == id }) else { return }
        goals.removeAll { $0.id == id }
        recordMutation()
        persistCurrentGoals()
    }

    private func load() async {
        let revisionAtStart = mutationRevision
        do {
            let loadedGoals = Self.sortedGoals(try await persistence.load())
            if mutationRevision == revisionAtStart {
                goals = loadedGoals
            } else {
                goals = Self.mergedGoals(loadedGoals, preservingLocalGoals: goals)
                persistCurrentGoals()
            }
            lastError = nil
        } catch {
            if mutationRevision == revisionAtStart {
                goals = []
            }
            lastError = error.localizedDescription
        }
    }

    private func updateGoal(
        id: UUID,
        _ mutate: (inout GoalSupervisionRecord, Date) -> Bool
    ) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        var goal = goals[index]
        let now = Date.now
        let didMutate = mutate(&goal, now)
        guard didMutate else { return }
        goal.updatedAt = now
        goals[index] = goal
        sortGoals()
        recordMutation()
        persistCurrentGoals()
    }

    private func sortGoals() {
        goals = Self.sortedGoals(goals)
    }

    private func recordMutation() {
        mutationRevision &+= 1
    }

    private static func mergedGoals(
        _ loadedGoals: [GoalSupervisionRecord],
        preservingLocalGoals localGoals: [GoalSupervisionRecord]
    ) -> [GoalSupervisionRecord] {
        var goalsByID: [UUID: GoalSupervisionRecord] = [:]
        for goal in loadedGoals {
            goalsByID[goal.id] = goal
        }
        for goal in localGoals {
            goalsByID[goal.id] = goal
        }
        return sortedGoals(Array(goalsByID.values))
    }

    private static func sortedGoals(_ goals: [GoalSupervisionRecord]) -> [GoalSupervisionRecord] {
        goals.sorted { lhs, rhs in
            if lhs.status == .active, rhs.status != .active { return true }
            if lhs.status != .active, rhs.status == .active { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func persistCurrentGoals() {
        let snapshot = goals
        persistTask?.cancel()
        persistTask = Task { [persistence] in
            do {
                try Task.checkCancellation()
                try await persistence.save(snapshot)
                try Task.checkCancellation()
                await MainActor.run { self.lastError = nil }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
