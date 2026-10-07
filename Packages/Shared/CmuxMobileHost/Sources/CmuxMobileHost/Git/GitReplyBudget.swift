import CmuxMobileWire
import Foundation

/// Keeps a `git.diff` reply under one frame (c13-viewers.md section 2):
/// drops the largest patches first (marking them truncated), then trailing
/// files (counted in `files_omitted`), until the encoded result fits.
struct GitReplyBudget {
    var maxBytes: Int

    func fit(_ result: GitDiffResult) -> GitDiffResult {
        let encoder = JSONEncoder()
        func size<T: Encodable>(_ value: T) -> Int { (try? encoder.encode(value).count) ?? 0 }
        var result = result
        var sizes = result.files.map { size($0) }
        var shell = result
        shell.files = []
        // Separators between files plus the result's own fields.
        var total = size(shell) + sizes.reduce(0, +) + max(0, sizes.count - 1)
        guard total > maxBytes else { return result }
        while total > maxBytes {
            let largest = result.files.indices.filter { result.files[$0].patch != nil }.max { sizes[$0] < sizes[$1] }
            guard let index = largest else { break }
            result.files[index].patch = nil
            result.files[index].patchTruncated = true
            let resized = size(result.files[index])
            total += resized - sizes[index]
            sizes[index] = resized
        }
        while total > maxBytes, !result.files.isEmpty {
            total -= sizes.removeLast() + (sizes.isEmpty ? 0 : 1)
            result.files.removeLast()
            result.filesOmitted += 1
        }
        return result
    }
}
