import Darwin
import Foundation
import Testing

@testable import CmuxBrowser

/// r22 native#1: `fs.copyFile` writes the source's bytes into a staging
/// file next to the destination and checks that no `secrets.load`
/// protected the source only before it publishes the copy. A session that
/// shares the directory must not reach that staging file in between: not
/// list it, read it, copy it, or load it in a tab. Otherwise a source that
/// another session's `secrets.load` protected during the copy is readable
/// under the staging name until the late check removes it.
@Suite("Browser REPL copyFile staging file", .serialized)
struct BrowserReplCopyStagingTests {
    private static let value = "st4ging-secret-5521"

    @Test("Another session cannot list, read, copy or load copyFile's staging file while the copy runs")
    func stagingFileIsUnreachableDuringTheCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brepl-copy-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = BrowserReplFileSandbox.canonicalize(directory.path)
        // Larger than one chunk, so the copy asks whether it was cancelled
        // with the staging file written in part: the forced point where
        // another session acts.
        var contents = Data(#"{"example.com":{"pw":"\#(Self.value)"}}"#.utf8)
        contents.append(Data(count: 2 * BrowserReplFileSystem.chunkBytes))
        try contents.write(to: URL(fileURLWithPath: root + "/secrets.json"))
        let sourceIdentity = try #require(BrowserReplFileIdentity(path: root + "/secrets.json"))

        let other = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: root))
        let observed = StagingObservation()
        let copier = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: root),
            temporaryDirectory: nil,
            rootDescriptor: nil,
            temporaryDescriptor: nil,
            writeBudget: BrowserReplWriteBudget(),
            isCancelled: {
                guard observed.begin() else { return false }
                // Another session's secrets.load protects the source now.
                try? BrowserReplSecretSources.shared.protect(sourceIdentity)
                let staging = (try? FileManager.default.contentsOfDirectory(atPath: root))?
                    .first { $0.contains(".cmux-copy-") }
                var listed = false
                if case .success(let entries as [[String: Any]]) = other.perform("readdir", arguments: ["path": "."]) {
                    listed = entries.contains { ($0["name"] as? String)?.contains(".cmux-copy-") == true }
                }
                var readBack: String?
                var copied = false
                var navigable = false
                if let staging {
                    if case .success(let base64 as String) = other.perform("readFile", arguments: ["path": staging]) {
                        // Only the part that holds the value, so a failure
                        // does not print megabytes of padding.
                        readBack = String(decoding: (Data(base64Encoded: base64) ?? Data()).prefix(64), as: UTF8.self)
                    }
                    if case .success = other.perform("copyFile", arguments: ["from": staging, "to": "stolen.json"]) { copied = true }
                    let url = URL(fileURLWithPath: root + "/" + staging).absoluteString
                    navigable = BrowserReplFileSandbox.navigationRefusal(url, roots: [root]) == nil
                }
                observed.finish(staging: staging, listed: listed, readBack: readBack, copied: copied, navigable: navigable)
                return false
            }
        )

        let result = copier.perform("copyFile", arguments: ["from": "secrets.json", "to": "copy.json"])

        let seen = try #require(observed.result, "the copy never reached its cancellation check with the staging file written")
        #expect(seen.staging != nil, "no staging file was found while the copy ran")
        #expect(!seen.listed, "another session's readdir listed the copy's staging file")
        #expect(!(seen.readBack ?? "").contains(Self.value), "another session read the protected source's bytes from the staging file")
        #expect(seen.readBack == nil, "another session's readFile of the staging file succeeded")
        #expect(!seen.copied, "another session copied the staging file")
        #expect(!seen.navigable, "a tab may load the staging file")
        var code: String?
        if case .failure(let error) = result { code = error.code }
        #expect(code == "denied", "the copy of a source protected meanwhile was not refused: \(result)")
        let left = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
        #expect(left == ["secrets.json"], "files left after the refused copy: \(left)")
    }
}

/// What the other session saw at the forced point, set once.
private final class StagingObservation: @unchecked Sendable {
    struct Seen {
        let staging: String?
        let listed: Bool
        let readBack: String?
        let copied: Bool
        let navigable: Bool
    }

    private let lock = NSLock()
    private var started = false
    private var stored: Seen?

    var result: Seen? { lock.withLock { stored } }

    /// True the first time only.
    func begin() -> Bool {
        lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
    }

    func finish(staging: String?, listed: Bool, readBack: String?, copied: Bool, navigable: Bool) {
        lock.withLock { stored = Seen(staging: staging, listed: listed, readBack: readBack, copied: copied, navigable: navigable) }
    }
}

/// r26 native#1: `fs.copyFile` checked that no `secrets.load` protected
/// its source, then published the copy in a later hold of
/// ``BrowserReplFileSandbox/pathChangeLock``. `secrets.load` protects under
/// that lock, so another session's load could land between the check and
/// the publish and the copy published the source's raw bytes anyway. The
/// check and the publish must be one hold of the lock.
@Suite("Browser REPL copyFile source protection and publish", .serialized)
struct BrowserReplCopyPublishProtectionTests {
    @Test("A secrets.load that protects the source before the copy publishes refuses the copy")
    func protectionBeforePublishRefusesTheCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brepl-copy-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = BrowserReplFileSandbox.canonicalize(directory.path)
        var contents = Data(#"{"example.com":{"pw":"publish-race-secret-7731"}}"#.utf8)
        contents.append(Data(count: 2 * BrowserReplFileSystem.chunkBytes))
        try contents.write(to: URL(fileURLWithPath: root + "/secrets.json"))
        let sourceIdentity = try #require(BrowserReplFileIdentity(path: root + "/secrets.json"))

        let started = StagingObservation()
        let held = DispatchSemaphore(value: 0)
        let loaderDone = DispatchSemaphore(value: 0)
        let copyDone = DispatchSemaphore(value: 0)
        let copier = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: root),
            temporaryDirectory: nil,
            rootDescriptor: nil,
            temporaryDescriptor: nil,
            writeBudget: BrowserReplWriteBudget(),
            isCancelled: {
                guard started.begin() else { return false }
                // Another session's secrets.load takes the lock it protects
                // under while the copy writes, and protects the source while
                // still holding it: after any check the copy made outside the
                // lock, before any publish.
                Thread.detachNewThread {
                    BrowserReplFileSandbox.pathChangeLock.withLock {
                        held.signal()
                        // Bounds the test's time only: the copy cannot finish
                        // while the lock is held.
                        _ = copyDone.wait(timeout: .now() + 1)
                        try? BrowserReplSecretSources.shared.protect(sourceIdentity)
                    }
                    loaderDone.signal()
                }
                held.wait()
                return false
            }
        )

        let result = copier.perform("copyFile", arguments: ["from": "secrets.json", "to": "copy.json"])
        copyDone.signal()
        loaderDone.wait()

        var code: String?
        if case .failure(let error) = result { code = error.code }
        #expect(code == "denied", "the copy published after another session protected its source: \(result)")
        let left = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
        #expect(left == ["secrets.json"], "files left after the refused copy: \(left)")
    }
}
