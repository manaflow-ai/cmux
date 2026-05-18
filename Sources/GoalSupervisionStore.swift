import Foundation
import Observation

private enum GoalSupervisionFileIO {
    private static let queue = DispatchQueue(
        label: "com.cmux.goal-supervision.file-io",
        qos: .utility
    )

    static func loadData(from fileURL: URL) async throws -> Data? {
        try Task.checkCancellation()
        let data = try await perform {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            return try Data(contentsOf: fileURL)
        }
        try Task.checkCancellation()
        return data
    }

    static func saveData(_ data: Data, to fileURL: URL) async throws {
        try Task.checkCancellation()
        try await perform {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        }
        try Task.checkCancellation()
    }

    private static func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}

actor GoalSupervisionPersistence {
    static let live = GoalSupervisionPersistence(fileURL: defaultFileURL())

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() async throws -> [GoalSupervisionRecord] {
        try Task.checkCancellation()
        guard let data = try await GoalSupervisionFileIO.loadData(from: fileURL) else {
            return []
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GoalSupervisionRecord].self, from: data)
    }

    func save(_ goals: [GoalSupervisionRecord]) async throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(goals)
        try Task.checkCancellation()
        try await GoalSupervisionFileIO.saveData(data, to: fileURL)
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
    static let loadFailureMessage = String(
        localized: "goals.error.load",
        defaultValue: "Goals couldn't be loaded. Check that cmux has permission to read its data folder."
    )
    static let saveFailureMessage = String(
        localized: "goals.error.save",
        defaultValue: "Goal changes couldn't be saved. Check that cmux has permission to write its data folder."
    )

    private(set) var goals: [GoalSupervisionRecord] = []
    private(set) var lastError: String?

    @ObservationIgnored private let persistence: GoalSupervisionPersistence
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var mutationRevision: UInt64 = 0
    @ObservationIgnored private var deletedGoalIDs: Set<UUID> = []
    @ObservationIgnored private var hasLoaded = false

    init(persistence: GoalSupervisionPersistence = .live) {
        self.persistence = persistence
        loadTask = Task { await load() }
    }

    func snapshots() -> [GoalSupervisionSnapshot] {
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

    func waitForInitialLoad() async {
        guard let loadTask else { return }
        await loadTask.value
    }

    func waitForPendingSave() async {
        guard let persistTask else { return }
        await persistTask.value
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
        deletedGoalIDs.insert(id)
        recordMutation()
        persistCurrentGoals()
    }

    private func load() async {
        let revisionAtStart = mutationRevision
        do {
            try Task.checkCancellation()
            let loadedGoals = Self.sortedGoals(try await persistence.load())
            try Task.checkCancellation()
            if mutationRevision == revisionAtStart {
                goals = loadedGoals
            } else {
                goals = Self.mergedGoals(
                    loadedGoals,
                    preservingLocalGoals: goals,
                    excluding: deletedGoalIDs
                )
                persistCurrentGoals()
            }
            hasLoaded = true
            if lastError != nil {
                lastError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if mutationRevision == revisionAtStart {
                goals = []
            }
            hasLoaded = true
            lastError = Self.loadFailureMessage
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
        preservingLocalGoals localGoals: [GoalSupervisionRecord],
        excluding deletedGoalIDs: Set<UUID>
    ) -> [GoalSupervisionRecord] {
        var goalsByID: [UUID: GoalSupervisionRecord] = [:]
        for goal in loadedGoals where !deletedGoalIDs.contains(goal.id) {
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
        let revisionAtStart = mutationRevision
        persistTask?.cancel()
        persistTask = Task { [persistence] in
            do {
                try Task.checkCancellation()
                try await persistence.save(snapshot)
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.mutationRevision == revisionAtStart else { return }
                    if self.hasLoaded {
                        self.deletedGoalIDs.removeAll()
                    }
                    if self.lastError != nil {
                        self.lastError = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { self.lastError = Self.saveFailureMessage }
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
