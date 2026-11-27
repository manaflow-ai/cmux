import Darwin
import Foundation

extension TerminalController {
    enum WorkspaceCreateWorkingDirectoryValidation: Equatable, Sendable {
        case notProvided
        case valid(String)
        case invalid
        case busy
        case timedOut
        case cancelled
    }

    typealias WorkspaceCreateWorkingDirectoryValidator = @Sendable (
        _ rawValue: String?,
        _ isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation

    nonisolated static let v2MaximumWorkingDirectoryUTF8Bytes = 4_096

    nonisolated static let v2MobileWorkingDirectoryValidationService =
        WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(3),
            localCapacity: 1,
            externalCapacity: 2,
            classificationCapacity: 3,
            maximumPendingWaiters: 64,
            maximumPathUTF8Bytes: v2MaximumWorkingDirectoryUTF8Bytes,
            laneClassifier: { @Sendable path in
                await Task.detached(priority: .utility) {
                    TerminalController.v2WorkingDirectoryProbeLane(path)
                }.value
            },
            probe: { path, lane in
                await TerminalController.v2ProbeWorkingDirectory(path, lane: lane)
            },
            sleepUntilDeadline: { timeout in
                try? await ContinuousClock().sleep(for: timeout)
            }
        )

    struct WorkspaceCreateMountEntry {
        let path: String
        let isLocal: Bool
    }

    private enum WorkspaceCreatePathInspection {
        case local(isDirectory: Bool)
        case external
    }

    nonisolated static func v2WorkingDirectoryProbeLane(
        _ path: String
    ) -> WorkspaceCreateWorkingDirectoryValidationService.ProbeLane {
        switch v2InspectWorkingDirectoryPath(path) {
        case .local:
            return .local
        case .external:
            return .external
        }
    }

    /// Runs the selected lane's probe without letting a path mutation redirect
    /// reserved local-lane work through a symbolic link.
    nonisolated static func v2ProbeWorkingDirectory(
        _ path: String,
        lane: WorkspaceCreateWorkingDirectoryValidationService.ProbeLane
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            switch lane {
            case .local:
                guard case let .local(isDirectory) = v2InspectWorkingDirectoryPath(path) else {
                    return false
                }
                return isDirectory
            case .external:
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }.value
    }

    /// Inspects every component relative to an already-open parent directory.
    /// Unknown mounts, symbolic links, and inspection failures are quarantined
    /// to the external lane. `O_NOFOLLOW` prevents a component-swap race from
    /// redirecting this walk through the link target.
    nonisolated private static func v2InspectWorkingDirectoryPath(
        _ path: String
    ) -> WorkspaceCreatePathInspection {
        guard (path as NSString).isAbsolutePath else { return .external }
        guard !v2WorkingDirectoryContainsDotComponent(path) else { return .external }
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        guard !normalizedPath.utf8.contains(0) else { return .external }
        let mounts = v2WorkingDirectoryMountEntries()
        guard v2WorkingDirectoryMountIsLocal(path: "/", mounts: mounts) == true else {
            return .external
        }

        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
        guard directoryFD >= 0 else { return .external }
        defer { close(directoryFD) }

        let components = normalizedPath.split(separator: "/").map(String.init)
        if components.isEmpty {
            var fileStatus = stat()
            guard fstat(directoryFD, &fileStatus) == 0 else { return .external }
            return .local(isDirectory: (fileStatus.st_mode & S_IFMT) == S_IFDIR)
        }

        var prefix = ""
        for (index, component) in components.enumerated() {
            prefix += "/\(component)"
            guard v2WorkingDirectoryMountIsLocal(path: prefix, mounts: mounts) == true else {
                return .external
            }

            var fileStatus = stat()
            let status = component.withCString {
                fstatat(directoryFD, $0, &fileStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { return .external }
            let fileType = fileStatus.st_mode & S_IFMT
            guard fileType != S_IFLNK else { return .external }
            if index == components.index(before: components.endIndex) {
                return .local(isDirectory: fileType == S_IFDIR)
            }
            guard fileType == S_IFDIR else { return .external }

            let nextDirectoryFD = component.withCString {
                openat(
                    directoryFD,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard nextDirectoryFD >= 0 else { return .external }
            close(directoryFD)
            directoryFD = nextDirectoryFD
        }
        return .external
    }

    nonisolated private static func v2WorkingDirectoryMountEntries() -> [WorkspaceCreateMountEntry] {
        var mountBuffer: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo_r_np(&mountBuffer, MNT_NOWAIT)
        defer {
            if let mountBuffer {
                free(UnsafeMutableRawPointer(mountBuffer))
            }
        }
        guard mountCount > 0, let mountBuffer else { return [] }

        var entries: [WorkspaceCreateMountEntry] = []
        entries.reserveCapacity(Int(mountCount))
        for index in 0..<Int(mountCount) {
            let fileSystem = mountBuffer[index]
            let path = withUnsafePointer(to: fileSystem.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            entries.append(WorkspaceCreateMountEntry(
                path: URL(fileURLWithPath: path).standardized.path,
                isLocal: (fileSystem.f_flags & UInt32(MNT_LOCAL)) != 0
            ))
        }
        return entries
    }

    nonisolated static func v2WorkingDirectoryMountIsLocal(
        path: String,
        mounts: [WorkspaceCreateMountEntry]
    ) -> Bool? {
        let foldedPath = v2CaseFoldedMountPath(path)
        var longestMatchLength = -1
        var longestMatchIsLocal: Bool?
        for mount in mounts {
            let foldedMountPath = v2CaseFoldedMountPath(mount.path)
            let matches = foldedPath == foldedMountPath
                || foldedPath.hasPrefix(
                    foldedMountPath == "/" ? "/" : "\(foldedMountPath)/"
                )
            guard matches else { continue }
            let matchLength = foldedMountPath.count
            if matchLength > longestMatchLength {
                longestMatchLength = matchLength
                longestMatchIsLocal = mount.isLocal
            } else if matchLength == longestMatchLength, !mount.isLocal {
                // Conflicting snapshots or case aliases fail into the bounded
                // external lane regardless of mount enumeration order.
                longestMatchIsLocal = false
            }
        }
        return longestMatchIsLocal
    }

    nonisolated static func v2WorkingDirectoryContainsDotComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0 == "." || $0 == ".."
        }
    }

    nonisolated private static func v2CaseFoldedMountPath(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    nonisolated static var v2InvalidWorkingDirectoryResult: V2CallResult {
        .err(
            code: "invalid_working_directory",
            message: "working_directory must be an absolute existing directory",
            data: ["field": "working_directory"]
        )
    }

    nonisolated static func v2ValidateMobileWorkingDirectory(
        rawValue: String?,
        isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation {
        guard !Task.isCancelled else { return .cancelled }
        guard !isProvided || (rawValue?.utf8.count ?? 0) <= v2MaximumWorkingDirectoryUTF8Bytes else {
            return .invalid
        }
        let validation = await v2MobileWorkingDirectoryValidationService.validate(
            rawValue: rawValue,
            isProvided: isProvided
        )
        guard !Task.isCancelled else { return .cancelled }
        return validation
    }
}
