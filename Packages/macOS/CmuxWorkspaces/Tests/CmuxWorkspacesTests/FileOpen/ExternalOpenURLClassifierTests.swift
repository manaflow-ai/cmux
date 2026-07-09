import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("ExternalOpenURLClassifier")
struct ExternalOpenURLClassifierTests {
    private let bundleURL = URL(fileURLWithPath: "/Applications/cmux.app", isDirectory: true)

    private func makeClassifier(
        orderedUniqueDirectories: @escaping @Sendable (_ pathURLs: [URL], _ excludedRootURLs: [URL]) -> [String] = { pathURLs, _ in
            pathURLs.map { $0.deletingLastPathComponent().path }
        }
    ) -> ExternalOpenURLClassifier {
        ExternalOpenURLClassifier(
            bundleURL: bundleURL,
            orderedUniqueDirectories: orderedUniqueDirectories
        )
    }

    private final class ExcludedRootsBox: @unchecked Sendable {
        // Test-only mutable capture; the classifier invokes the injected
        // closure synchronously on this thread, so no real concurrency.
        var value: [URL] = []
    }

    @Test("directories filters to file URLs and forwards excluded bundle root")
    func directoriesForwardsBundleExclusion() {
        let box = ExcludedRootsBox()
        let classifier = makeClassifier { pathURLs, excludedRootURLs in
            box.value = excludedRootURLs
            return pathURLs.map(\.path)
        }
        let httpURL = URL(string: "https://example.com")!
        let fileURL = URL(fileURLWithPath: "/tmp/project")

        let directories = classifier.directories(from: [httpURL, fileURL])

        #expect(directories == ["/tmp/project"])
        #expect(box.value == [bundleURL])
    }

    @Test("isDirectory reports true only for file-URL directories")
    func isDirectoryClassifiesPaths() throws {
        let classifier = makeClassifier()
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: fileURL)

        #expect(classifier.isDirectory(tempDir) == true)
        #expect(classifier.isDirectory(fileURL) == false)
        #expect(classifier.isDirectory(URL(string: "https://example.com")!) == false)
    }

    @Test("fileURLs drops directories, bundle descendants, and duplicates")
    func fileURLsExcludesAndDedupes() throws {
        let classifier = makeClassifier()
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: fileURL)
        let bundleChild = bundleURL.appendingPathComponent("Contents/info.plist")

        let result = classifier.fileURLs(from: [tempDir, fileURL, fileURL, bundleChild])

        #expect(result == [fileURL.standardizedFileURL])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ExternalOpenURLClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
