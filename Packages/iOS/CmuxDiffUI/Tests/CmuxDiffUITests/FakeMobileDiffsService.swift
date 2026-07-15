import CmuxMobileRPC
import CmuxMobileShell

actor FakeMobileDiffsService: MobileDiffsServing {
    private var summaries: [FakeDiffResponse<MobileDiffSummaryResponse>]
    private var files: [FakeDiffResponse<MobileDiffFileResponse>]
    private var contexts: [FakeDiffResponse<MobileDiffContextResponse>]
    private(set) var requestedCursors: [Int?] = []
    private(set) var requestedForces: [Bool] = []
    private(set) var requestedContextRanges: [ClosedRange<Int>] = []

    init(
        summaries: [FakeDiffResponse<MobileDiffSummaryResponse>],
        files: [FakeDiffResponse<MobileDiffFileResponse>] = [],
        contexts: [FakeDiffResponse<MobileDiffContextResponse>] = []
    ) {
        self.summaries = summaries
        self.files = files
        self.contexts = contexts
    }

    func summary(
        workspaceRef: String,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool
    ) async throws -> MobileDiffSummaryResponse {
        try resolve(summaries.removeFirst())
    }

    func fileHunks(
        workspaceRef: String,
        path: String,
        oldPath: String?,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool,
        cursor: Int?,
        force: Bool
    ) async throws -> MobileDiffFileResponse {
        requestedCursors.append(cursor)
        requestedForces.append(force)
        return try resolve(files.removeFirst())
    }

    func contextRows(
        workspaceRef: String,
        path: String,
        startLine: Int,
        endLine: Int,
        baseSpec: MobileDiffBaseSpec,
        ignoreWhitespace: Bool
    ) async throws -> MobileDiffContextResponse {
        requestedContextRanges.append(startLine...endLine)
        return try resolve(contexts.removeFirst())
    }

    private func resolve<Value: Sendable>(_ response: FakeDiffResponse<Value>) throws -> Value {
        switch response {
        case let .success(value):
            value
        case let .serviceFailure(error):
            throw error
        case .transportFailure:
            throw FakeDiffTransportError()
        }
    }
}
