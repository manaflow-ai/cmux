import Foundation
import CmuxNextSettings
import Testing

/// A batch of checks (one picker answer) reads each folder on the way to its paths once, and
/// answers as the validator does.
struct ChatRootValidatorBatchTests {
    /// Every path the validator asked `readlink` about.
    private final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    @Test func aBatchReadsEachFolderOnce() {
        let links = Links()
        let validator = ChatRootValidator(home: "/Users/someone") { path in
            links.add(path)
            return nil
        }
        let before = links.all.count
        let batch = validator.batch()
        let files = (0..<10).map { "/Users/someone/code/app\($0)/.git/HEAD" }
        for file in files { #expect(batch.refusal(file) == nil) }
        let asked = links.all.dropFirst(before)
        #expect(asked.count == Set(asked).count, "asked twice: \(Array(asked))")
        // `/Users`, the home folder and `code` once; each app folder, its `.git` and its `HEAD` once.
        #expect(asked.count == 3 + 10 * 3)
    }

    @Test func aBatchAnswersAsTheValidatorDoes() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("validator-batch-\(UUID().uuidString)/home").path
        try FileManager.default.createDirectory(atPath: made + "/Documents/site", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/code/site", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: made + "/code/docs", withDestinationPath: made + "/Documents/site")
        guard let resolved = realpath(made, nil) else { throw CocoaError(.fileNoSuchFile) }
        let home = String(cString: resolved)
        free(resolved)
        defer { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
        let validator = ChatRootValidator(home: home)
        let batch = validator.batch()
        let paths = [home, home + "/code/site", home + "/code/site/.git/HEAD", home + "/code/docs", home + "/code/docs/x",
                     home + "/Documents", home + "/Documentſ/site", "/System/Volumes/Data" + home + "/Documents/site", "/", "relative"]
        for _ in 0..<2 {
            for path in paths {
                #expect(batch.refusal(path) == validator.refusal(path), "refusal of \(path)")
                #expect(batch.reachesProtectedFolder(path) == validator.reachesProtectedFolder(path), "reach of \(path)")
            }
        }
        #expect(batch.refusal(home + "/code/docs") != nil, "a link into Documents is refused in a batch too")
    }
}
