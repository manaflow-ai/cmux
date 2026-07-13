import Foundation
@testable import CmuxOrchestration

/// In-memory filesystem fake shared by store/validator/planner tests.
final class InMemoryFileSystem: OrchestrationFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var executablePaths: Set<String> = []

    init() {}

    // MARK: - Test helpers

    func addFile(_ path: String, _ contents: String, executable: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        files[normalize(path)] = Data(contents.utf8)
        if executable { executablePaths.insert(normalize(path)) }
        addParentDirectories(of: normalize(path))
    }

    func addDirectory(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        directories.insert(normalize(path))
        addParentDirectories(of: normalize(path))
    }

    func fileContents(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return files[normalize(path)].flatMap { String(data: $0, encoding: .utf8) }
    }

    var allFilePaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return files.keys.sorted()
    }

    // MARK: - OrchestrationFileSystem

    func fileExists(atPath path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[normalize(path)] != nil
    }

    func directoryExists(atPath path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return directories.contains(normalize(path))
    }

    func isExecutableFile(atPath path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return executablePaths.contains(normalize(path))
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let base = normalize(path)
        guard directories.contains(base) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let prefix = base + "/"
        var children: Set<String> = []
        for file in files.keys where file.hasPrefix(prefix) {
            children.insert(String(file.dropFirst(prefix.count)).split(separator: "/")[0].description)
        }
        for directory in directories where directory.hasPrefix(prefix) {
            children.insert(String(directory.dropFirst(prefix.count)).split(separator: "/")[0].description)
        }
        return children.sorted()
    }

    func readData(atPath path: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = files[normalize(path)] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func writeData(_ data: Data, atPath path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        files[normalize(path)] = data
        addParentDirectories(of: normalize(path))
    }

    func createDirectory(atPath path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        directories.insert(normalize(path))
        addParentDirectories(of: normalize(path))
    }

    func removeItem(atPath path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let target = normalize(path)
        let prefix = target + "/"
        let existed = files[target] != nil || directories.contains(target)
        files = files.filter { !$0.key.hasPrefix(prefix) && $0.key != target }
        directories = directories.filter { !$0.hasPrefix(prefix) && $0 != target }
        executablePaths = executablePaths.filter { !$0.hasPrefix(prefix) && $0 != target }
        if !existed {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    func copyItem(atPath source: String, toPath destination: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let from = normalize(source)
        let to = normalize(destination)
        if let data = files[from] {
            files[to] = data
            addParentDirectories(of: to)
            return
        }
        guard directories.contains(from) else {
            throw CocoaError(.fileNoSuchFile)
        }
        directories.insert(to)
        addParentDirectories(of: to)
        let prefix = from + "/"
        for (path, data) in files where path.hasPrefix(prefix) {
            let copied = to + "/" + String(path.dropFirst(prefix.count))
            files[copied] = data
            addParentDirectories(of: copied)
            if executablePaths.contains(path) { executablePaths.insert(copied) }
        }
        for directory in directories where directory.hasPrefix(prefix) {
            directories.insert(to + "/" + String(directory.dropFirst(prefix.count)))
        }
    }

    // MARK: - Private

    private func normalize(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func addParentDirectories(of path: String) {
        var components = path.split(separator: "/").dropLast()
        while !components.isEmpty {
            directories.insert("/" + components.joined(separator: "/"))
            components = components.dropLast()
        }
    }
}

/// Git fake: "clones" by materializing a canned template directory.
final class FakeGitClient: OrchestrationGitClient, @unchecked Sendable {
    private let lock = NSLock()
    private let fileSystem: InMemoryFileSystem
    var filesByURL: [String: [(path: String, contents: String)]] = [:]
    var commit: String? = "abc1234"
    private(set) var cloneCalls: [(url: String, reference: String?, path: String)] = []

    init(fileSystem: InMemoryFileSystem) {
        self.fileSystem = fileSystem
    }

    func clone(url: String, reference: String?, toPath path: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        cloneCalls.append((url, reference, path))
        guard let entries = filesByURL[url] else {
            throw OrchestrationGitError(message: "fatal: repository '\(url)' not found")
        }
        fileSystem.addDirectory(path)
        for entry in entries {
            fileSystem.addFile(path + "/" + entry.path, entry.contents)
        }
        return commit
    }
}

/// A minimal valid manifest JSON used across suites.
func minimalManifestJSON(
    name: String = "demo-fleet",
    substrate: String = "{ \"kind\": \"worktree\" }",
    extra: String = ""
) -> String {
    """
    {
      "schemaVersion": 1,
      "name": "\(name)",
      "version": "1.0.0",
      "description": "Demo fleet",
      "parameters": [
        { "key": "repo_root", "prompt": "Repo path", "type": "path" },
        { "key": "concurrency", "prompt": "Cap", "type": "int", "default": 2 }
      ],
      "substrate": \(substrate),
      "agents": [
        { "id": "claude", "registryAgent": "claude", "command": "claude {{prompt}}" }
      ],
      "prompt": "prompts/task.md"\(extra)
    }
    """
}

/// Materializes a valid template directory on the fake filesystem.
@discardableResult
func addMinimalTemplate(
    to fileSystem: InMemoryFileSystem,
    at path: String,
    name: String = "demo-fleet",
    substrate: String = "{ \"kind\": \"worktree\" }",
    extra: String = ""
) -> String {
    fileSystem.addDirectory(path)
    fileSystem.addFile(path + "/orchestration.json", minimalManifestJSON(name: name, substrate: substrate, extra: extra))
    fileSystem.addFile(path + "/prompts/task.md", "Do this: {{task}} in {{workspace_dir}} on {{branch}}")
    return path
}
