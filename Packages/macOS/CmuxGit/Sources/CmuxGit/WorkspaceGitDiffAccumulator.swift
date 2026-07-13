import Foundation

/// Incrementally enforces the mobile unified-diff response byte cap.
struct WorkspaceGitDiffAccumulator: Sendable {
    private let byteCap: Int
    private(set) var patch = ""
    private(set) var included: [String] = []
    private(set) var truncated: [String] = []
    private(set) var tooLarge: [WorkspaceGitTooLargePath] = []
    private var patchByteCount = 0

    init(byteCap: Int) {
        self.byteCap = byteCap
    }

    /// Adds one generated per-path patch and returns whether accumulation can continue.
    mutating func append(path: String, patch nextPatch: String) -> Bool {
        let byteCount = nextPatch.utf8.count
        if byteCount > byteCap {
            tooLarge.append(WorkspaceGitTooLargePath(path: path, bytes: byteCount))
            return true
        }
        guard !nextPatch.isEmpty else {
            return true
        }
        guard patchByteCount + byteCount <= byteCap else {
            truncated.append(path)
            return false
        }
        patch += nextPatch
        patchByteCount += byteCount
        included.append(path)
        return true
    }

    /// Marks paths after the first cap crossing as truncated without generating them.
    mutating func appendTruncated<S: Sequence>(contentsOf paths: S) where S.Element == String {
        truncated.append(contentsOf: paths)
    }

    /// Builds the wire-facing value from the accumulated state.
    func response() -> WorkspaceGitDiff {
        WorkspaceGitDiff(
            baseline: "worktree",
            patch: patch,
            included: included,
            truncated: truncated,
            tooLarge: tooLarge
        )
    }
}
