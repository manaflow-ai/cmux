import Foundation

/// Resolves command names against an injected environment and filesystem.
struct CommandPathResolver: Sendable {
    private let environment: [String: String]
    private let bundledBinPath: String?
    private let fallbackSearchDirectories: [String]
    // FileManager is documented thread-safe; this immutable injected instance
    // has no delegate or mutable caller-owned state.
    private nonisolated(unsafe) let fileManager: FileManager

    init(
        environment: [String: String],
        bundledBinPath: String?,
        fallbackSearchDirectories: [String],
        fileManager: FileManager
    ) {
        self.environment = environment
        self.bundledBinPath = bundledBinPath
        self.fallbackSearchDirectories = fallbackSearchDirectories
        self.fileManager = fileManager
    }

    func resolve(_ executable: String) -> String? {
        guard !executable.isEmpty else { return nil }
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []
        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        appendSearchPath(bundledBinPath)
        fallbackSearchDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
