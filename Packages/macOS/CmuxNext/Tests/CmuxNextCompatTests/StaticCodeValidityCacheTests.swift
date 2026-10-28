@testable import CmuxNextCompat
import Darwin
import Foundation
import Security
import Testing

/// Code signature checks on disk are kept per version of the code (plans/cmux-next/chrome-parity/p02-threads.md,
/// tasks 054-055): the same unchanged item is hashed once; a rewrite, a replace by rename or a re-seal checks it
/// again. Each test counts the injected check's calls on files it makes in its own temporary folder.
@Suite(.serialized) struct StaticCodeValidityCacheTests {
    /// A check that answers `valid` and counts its calls.
    nonisolated final class CountingCheck: Sendable {
        private let count = Mutex(0)
        let valid: Bool

        init(valid: Bool) { self.valid = valid }

        var calls: Int { count.withLock { $0 } }

        func check(_ url: URL, _ flags: SecCSFlags, _ requirement: String?) -> Bool {
            count.withLock { $0 += 1 }
            return valid
        }
    }

    private let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "code-validity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anUnchangedFileIsCheckedOnce() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: "acpmux")
        try Data("binary".utf8).write(to: tool)
        let counter = CountingCheck(valid: true)
        let cache = StaticCodeValidityCache(check: counter.check)

        #expect(cache.isValid(tool, flags: flags, requirement: "anchor apple generic"))
        #expect(cache.isValid(tool, flags: flags, requirement: "anchor apple generic"))
        #expect(counter.calls == 1)
    }

    @Test func anotherRequirementOrFlagsIsAnotherCheck() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: "acpmux")
        try Data("binary".utf8).write(to: tool)
        let counter = CountingCheck(valid: false)
        let cache = StaticCodeValidityCache(check: counter.check)

        #expect(!cache.isValid(tool, flags: flags, requirement: "anchor apple generic"))
        #expect(!cache.isValid(tool, flags: flags, requirement: nil))
        #expect(!cache.isValid(tool, flags: [], requirement: nil))
        #expect(counter.calls == 3)
    }

    @Test func aReplacedFileIsCheckedAgain() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: "acpmux")
        try Data("binary".utf8).write(to: tool)
        let counter = CountingCheck(valid: true)
        let cache = StaticCodeValidityCache(check: counter.check)
        _ = cache.isValid(tool, flags: flags, requirement: nil)

        // An installer's replace: a new file renamed over the old one (a new inode, same size).
        let replacement = root.appending(path: "acpmux.new")
        try Data("BINARY".utf8).write(to: replacement)
        #expect(rename(replacement.path, tool.path) == 0)
        _ = cache.isValid(tool, flags: flags, requirement: nil)
        #expect(counter.calls == 2)

        // An in-place write of the same size moves the status-change time.
        let handle = try FileHandle(forWritingTo: tool)
        try handle.write(contentsOf: Data("binary".utf8))
        try handle.close()
        _ = cache.isValid(tool, flags: flags, requirement: nil)
        #expect(counter.calls == 3)
    }

    @Test func aBundleIsCheckedAgainWhenItsSealOrExecutableChanges() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Helper.app", directoryHint: .isDirectory)
        let seal = app.appending(path: "Contents/_CodeSignature/CodeResources")
        let executable = app.appending(path: "Contents/MacOS/helper")
        try FileManager.default.createDirectory(at: seal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: seal)
        try Data("code".utf8).write(to: executable)
        let counter = CountingCheck(valid: true)
        let cache = StaticCodeValidityCache(check: counter.check)

        _ = cache.isValid(app, flags: flags, requirement: nil)
        _ = cache.isValid(app, flags: flags, requirement: nil)
        #expect(counter.calls == 1)

        try Data("re-sealed".utf8).write(to: seal)  // a re-sign rewrites the seal
        _ = cache.isValid(app, flags: flags, requirement: nil)
        #expect(counter.calls == 2)

        try Data("other code".utf8).write(to: executable)  // the code changed inside the same folder
        _ = cache.isValid(app, flags: flags, requirement: nil)
        #expect(counter.calls == 3)
    }

    /// A strict check with `kSecCSCheckNestedCode` validates nested code too (a framework's `Libraries/*.dylib`, a
    /// helper app's `Contents/Frameworks/**`); an in-place write of one, or an added file, checks the bundle again.
    @Test func aBundleIsCheckedAgainWhenNestedCodeChanges() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appending(path: "Chromium Embedded Framework.framework", directoryHint: .isDirectory)
        let seal = framework.appending(path: "Versions/A/_CodeSignature/CodeResources")
        let library = framework.appending(path: "Versions/A/Libraries/libEGL.dylib")
        try FileManager.default.createDirectory(at: seal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: framework.appending(path: "Versions/Current").path, withDestinationPath: "A")
        try Data("seal".utf8).write(to: seal)
        try Data("dylib".utf8).write(to: library)
        let nested = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        let counter = CountingCheck(valid: true)
        let cache = StaticCodeValidityCache(check: counter.check)

        _ = cache.isValid(framework, flags: nested, requirement: nil)
        _ = cache.isValid(framework, flags: nested, requirement: nil)
        #expect(counter.calls == 1)

        // An in-place write of the same size: neither the seal nor the folder changes, only the dylib's status.
        let handle = try FileHandle(forWritingTo: library)
        try handle.write(contentsOf: Data("DYLIB".utf8))
        try handle.close()
        _ = cache.isValid(framework, flags: nested, requirement: nil)
        #expect(counter.calls == 2)

        try Data("extra".utf8).write(to: library.deletingLastPathComponent().appending(path: "libextra.dylib"))
        _ = cache.isValid(framework, flags: nested, requirement: nil)
        #expect(counter.calls == 3)
    }

    @Test func missingCodeIsNotValidAndNotChecked() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = CountingCheck(valid: true)
        let cache = StaticCodeValidityCache(check: counter.check)

        #expect(!cache.isValid(root.appending(path: "absent"), flags: flags, requirement: nil))
        #expect(counter.calls == 0)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The real check goes through the checked seam: on the main thread it records one system-call site at its caller;
    /// on a named serial queue (a lane) it records none.
    @MainActor @Test func theRealCheckIsACheckedSystemCall() async throws {
        let table = BlockingViolationTable(mode: .record)
        let line: UInt = #line + 1
        _ = BlockingViolationTable.$scoped.withValue(table) { StaticCodeValidityCache.checkValidity(URL(fileURLWithPath: "/usr/bin/true"), flags: [], requirement: nil) }
        await table.flush()
        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.systemCall])
        #expect(sites.map(\.location) == ["CmuxNextCompatTests/StaticCodeValidityCacheTests.swift:\(line)"])

        let offMain = BlockingViolationTable(mode: .record)
        let queue = DispatchQueue(label: "test.code-validity")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                _ = BlockingViolationTable.$scoped.withValue(offMain) {
                    StaticCodeValidityCache.checkValidity(URL(fileURLWithPath: "/usr/bin/true"), flags: [], requirement: nil)
                }
                done.resume()
            }
        }
        await offMain.flush()
        #expect(BlockingDetector(table: offMain).sites.isEmpty)
    }
    #endif
}
