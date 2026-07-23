import CmuxFleet
import Foundation

struct FleetTestSupport {
    static let taskID = FleetTaskID("github:manaflow-ai/cmux#7361")
    static let otherTaskID = FleetTaskID("github:manaflow-ai/cmux#9999")
    static let baseDate = Date(timeIntervalSince1970: 1_000)
    static let eventDate = Date(timeIntervalSince1970: 2_000)

    static func task(
        id: FleetTaskID = taskID,
        state: FleetTaskState = .queued,
        attempts: Int = 1,
        priority: Int? = nil,
        isBlocked: Bool = false,
        createdAt: Date = baseDate,
        pr: FleetPullRequestStatus? = nil,
        lastError: String? = nil
    ) -> FleetTask {
        FleetTask(
            id: id,
            sourceKind: .github,
            key: id.rawValue,
            title: "Fleet task",
            body: "Implement Fleet",
            labels: [],
            priority: priority,
            sourceState: "open",
            isBlocked: isBlocked,
            createdAt: createdAt,
            updatedAt: baseDate,
            state: state,
            attempts: attempts,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            pr: pr,
            lastError: lastError,
            lastActivityAt: baseDate
        )
    }

    static func task(
        idSuffix: String,
        state: FleetTaskState = .queued,
        attempts: Int = 1,
        priority: Int? = nil,
        isBlocked: Bool = false,
        createdAt: Date = baseDate,
        pr: FleetPullRequestStatus? = nil,
        lastError: String? = nil
    ) -> FleetTask {
        let id = FleetTaskID("local:\(idSuffix)")
        return task(
            id: id,
            state: state,
            attempts: attempts,
            priority: priority,
            isBlocked: isBlocked,
            createdAt: createdAt,
            pr: pr,
            lastError: lastError
        )
    }
}
