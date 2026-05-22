import Foundation

struct CodexTranscriptMonitorRequest: Sendable {
    let workspaceId: UUID
    let surfaceId: UUID?
    let sessionId: String
    let turnId: String?
    let transcriptPath: String?
    let codexHome: String?
}

struct CodexTranscriptFailureSummary: Sendable {
    let statusValue: String
    let subtitle: String
    let body: String
}

enum CodexTranscriptMonitorEvent: Sendable {
    case userInput(request: CodexTranscriptMonitorRequest, body: String)
    case failure(request: CodexTranscriptMonitorRequest, summary: CodexTranscriptFailureSummary)
    case completion(request: CodexTranscriptMonitorRequest)
}
