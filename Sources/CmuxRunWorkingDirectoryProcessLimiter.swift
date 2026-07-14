import Foundation

actor CmuxRunWorkingDirectoryProcessLimiter {
    static let shared = CmuxRunWorkingDirectoryProcessLimiter()

    private var isResolving = false

    func acquire() -> Bool {
        guard !isResolving else { return false }
        isResolving = true
        return true
    }

    func release() {
        isResolving = false
    }
}
