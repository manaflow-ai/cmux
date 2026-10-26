import CryptoKit
import Foundation
@testable import CmuxNextChromiumRuntime

/// A temporary folder per test, removed on deinit.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "chromium-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Builds small runtime packs with the real `tar`, shaped like the release
/// ones (one flat runtime folder: framework, shim, helpers).
struct PackFixture {
    static let runtimeFolder = "cmux TEST Chromium"

    enum Shape {
        case complete
        case missingHelper
        case symlinkOutside
    }

    /// Writes a pack for `shape` into `folder` and returns its bytes and pin.
    static func make(in folder: URL, shape: Shape = .complete, key: String = "0123456789abcdef",
                     shimABI: String = "abi-1", teamID: String? = nil) throws -> (data: Data, pin: ChromiumRuntimePin) {
        let tree = folder.appending(path: "tree-\(UUID().uuidString)", directoryHint: .isDirectory)
        let frameworks = tree.appending(path: runtimeFolder, directoryHint: .isDirectory)
        let framework = frameworks.appending(path: "Chromium Embedded Framework.framework/Versions/A", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: framework.appending(path: "Chromium Embedded Framework"))
        try fileManager.createSymbolicLink(atPath: frameworks.appending(path: "Chromium Embedded Framework.framework/Versions/Current").path,
                                           withDestinationPath: "A")
        try Data("shim".utf8).write(to: frameworks.appending(path: "libcmux_cef_shim.dylib"))
        var helpers = ["cmux TEST Helper (GPU).app", "cmux TEST Helper (Renderer).app"]
        if shape != .missingHelper { helpers.append("cmux TEST Helper.app") }
        for helper in helpers {
            let macOS = frameworks.appending(path: "\(helper)/Contents/MacOS", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data("helper".utf8).write(to: macOS.appending(path: "helper"))
        }
        if shape == .symlinkOutside {
            try fileManager.createSymbolicLink(atPath: frameworks.appending(path: "escape").path, withDestinationPath: "../../../../../../etc")
        }
        try Data("{}".utf8).write(to: tree.appending(path: ChromiumRuntimePin.resourceName))
        let archive = folder.appending(path: "pack-\(UUID().uuidString).tar.xz")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-cJf", archive.path, "-C", tree.path, runtimeFolder, ChromiumRuntimePin.resourceName]
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: archive)
        let pin = ChromiumRuntimePin(key: key, cef: "154.0.28", chromium: "154.0.8037.58", shimABI: shimABI,
                                     sha256: sha256(data), size: Int64(data.count),
                                     url: URL(string: "https://files.example.com/cef-runtime/\(key)/pack.tar.xz")!,
                                     teamID: teamID, folder: runtimeFolder)
        return (data, pin)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Serves `bytes` from memory, appending after what the file holds (a resume).
actor MemoryDownloader: ChromiumRuntimeDownloading {
    private var bytes: Data
    private var failuresLeft: Int
    private(set) var offsets: [Int64] = []
    private(set) var calls = 0

    init(bytes: Data, failFirst: Int = 0) {
        self.bytes = bytes
        failuresLeft = failFirst
    }

    func replace(with bytes: Data) { self.bytes = bytes }

    nonisolated func download(_ url: URL, to file: URL, expectedSize: Int64,
                              progress: @escaping @Sendable (Int64) -> Void) async throws(ChromiumRuntimeInstallError) {
        try await serve(file, progress: progress)
    }

    private func serve(_ file: URL, progress: @escaping @Sendable (Int64) -> Void) throws(ChromiumRuntimeInstallError) {
        calls += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw .transfer("connection reset")
        }
        let existing = ChromiumRuntimeInstaller.size(of: file)
        offsets.append(existing)
        var whole = (try? Data(contentsOf: file)) ?? Data()
        whole.append(bytes.dropFirst(Int(existing)))
        do { try whole.write(to: file) } catch { throw .filesystem(error.localizedDescription) }
        progress(Int64(whole.count))
    }
}

/// An unpacker that reports fixed entries (and extracts nothing).
struct FixedEntriesUnpacker: ChromiumRuntimeUnpacking {
    let names: [String]
    func entries(of archive: URL) async throws(ChromiumRuntimeInstallError) -> [String] { names }
    func unpack(_ archive: URL, into directory: URL) async throws(ChromiumRuntimeInstallError) {}
}

/// Records every checked item and the job priority it was checked at; fails the items whose names contain
/// `failing` with `failure` (default: a signature failure).
actor RecordingSignatures: ChromiumRuntimeSignatureChecking {
    private let failing: String?
    private let failure: ChromiumRuntimeInstallError?
    private(set) var checked: [String] = []
    private(set) var teams: Set<String> = []
    private(set) var priorities: [ChromiumRuntimeInstaller.Priority] = []

    init(failing: String? = nil, failure: ChromiumRuntimeInstallError? = nil) {
        self.failing = failing
        self.failure = failure
    }

    nonisolated func check(_ item: URL, teamID: String,
                           priority: ChromiumRuntimeInstaller.Priority) async throws(ChromiumRuntimeInstallError) {
        try await record(item.lastPathComponent, teamID, priority)
    }

    private func record(_ name: String, _ teamID: String,
                        _ priority: ChromiumRuntimeInstaller.Priority) throws(ChromiumRuntimeInstallError) {
        checked.append(name)
        teams.insert(teamID)
        priorities.append(priority)
        if let failing, name.contains(failing) { throw failure ?? .signature(name) }
    }
}

/// A network with a fixed answer. Waiting for a path it does not have lasts
/// until the waiting task is cancelled.
struct FixedNetwork: ChromiumRuntimeNetwork {
    /// Usable for user downloads.
    var online = true
    /// Usable for background prefetches too (not constrained or expensive).
    var unmetered = true

    func isUsable(allowsExpensive: Bool) async -> Bool { online && (allowsExpensive || unmetered) }

    func waitUntilUsable(allowsExpensive: Bool) async throws {
        if await isUsable(allowsExpensive: allowsExpensive) { return }
        let (never, _) = AsyncStream.makeStream(of: Void.self)
        for await _ in never {}
        try Task.checkCancellation()
    }
}
