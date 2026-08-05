import Foundation

/// Storage identity and retention policy for one transcript read.
struct SessionTranscriptSource: Sendable {
    let agent: SessionAgent
    let sessionId: String
    let fileURL: URL?
    let usesGrokTranscriptLayout: Bool
    let openCodeDatabasePath: String?
    let hermesStateDatabaseURL: URL?
    let retention: SessionTranscriptRetention

    init(
        agent: SessionAgent,
        sessionId: String,
        fileURL: URL?,
        usesGrokTranscriptLayout: Bool = false,
        openCodeDatabasePath: String? = nil,
        hermesStateDatabaseURL: URL? = nil,
        retention: SessionTranscriptRetention = .prefix(500)
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.fileURL = fileURL
        self.usesGrokTranscriptLayout = usesGrokTranscriptLayout
        self.openCodeDatabasePath = openCodeDatabasePath
        self.hermesStateDatabaseURL = hermesStateDatabaseURL
        self.retention = retention
    }
}
