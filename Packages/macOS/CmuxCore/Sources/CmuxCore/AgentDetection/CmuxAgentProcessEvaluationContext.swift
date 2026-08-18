/// Precomputed process fields reused across every candidate matcher in one
/// detection request.
struct CmuxAgentProcessEvaluationContext: Sendable {
    let process: CmuxAgentProcessSnapshot
    let executableBasenames: [String]
    let executableBasenamesByteCount: Int
    let normalizedProcessPath: String?
    let processPathByteCount: Int
    let argumentsByteCount: Int

    init(process: CmuxAgentProcessSnapshot) {
        let basenames = process.executableBasenames
        self.process = process
        self.executableBasenames = basenames
        self.executableBasenamesByteCount = basenames.reduce(0) {
            $0 + $1.utf8.count
        }
        let normalizedPath = process.processPath?.replacingOccurrences(of: "\\", with: "/")
        self.normalizedProcessPath = normalizedPath
        self.processPathByteCount = normalizedPath?.utf8.count ?? 0
        self.argumentsByteCount = process.arguments.reduce(0) {
            $0 + $1.utf8.count
        }
    }
}
