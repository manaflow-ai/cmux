import CmuxTopMemory
import Darwin
import Foundation

/// Compatibility names for the app-facing top-memory payload code.
typealias CmuxTopProcessOwnershipReason = CmuxTopMemoryOwnershipReason
typealias CmuxTopTerminalProcessOwnership = CmuxTopMemoryTerminalOwnership

extension CmuxTopProcessSnapshot {
    /// Resolves ownership using the immutable process records in this snapshot.
    ///
    /// Process enumeration and bundle identity stay in the app target; the
    /// package resolver receives only value records and trusted full paths.
    func terminalProcessOwnership(
        surfaceID: UUID?,
        ttyName: String?,
        applicationPID: Int = Int(Darwin.getpid())
    ) -> CmuxTopMemoryTerminalOwnership {
        let ttyDevice = ttyName.flatMap(Self.deviceIdentifier(forTTYName:))
        return terminalProcessOwnership(
            surfaceID: surfaceID,
            ttyDevice: ttyDevice,
            applicationPID: applicationPID
        )
    }

    /// Resolves ownership from a device number, keeping tests independent of
    /// the host's live device-node names.
    func terminalProcessOwnership(
        surfaceID: UUID?,
        ttyDevice: Int64?,
        applicationPID: Int = Int(Darwin.getpid())
    ) -> CmuxTopMemoryTerminalOwnership {
        let records = processesByPID.values.map { process in
            CmuxTopMemoryProcessRecord(
                pid: process.pid,
                parentPID: process.parentPID,
                path: process.path ?? ownershipPath(for: process, applicationPID: applicationPID),
                ttyDevice: process.ttyDevice,
                workspaceID: process.cmuxWorkspaceID,
                surfaceID: process.cmuxSurfaceID,
                attributionReason: process.cmuxAttributionReason,
                processGroupID: process.processGroupID
            )
        }
        let resolver = CmuxTopProcessOwnershipResolver(processes: records)
        return resolver.resolve(
            surfaceID: surfaceID,
            ttyDevice: ttyDevice,
            applicationPID: applicationPID,
            trustedExecutablePaths: trustedCMUXExecutablePaths(applicationPID: applicationPID)
        )
    }

    /// Loads paths only for the app and TTY processes that can affect helper
    /// ownership, keeping ordinary top snapshots on their cheap path.
    private func ownershipPath(for process: CmuxTopProcessInfo, applicationPID: Int) -> String? {
        guard process.pid == applicationPID || process.ttyDevice != nil else { return nil }
        return Self.executablePathForOwnership(pid: process.pid)
    }

    /// Derives trusted helper paths from the running app bundle identity.
    private func trustedCMUXExecutablePaths(applicationPID: Int) -> Set<String> {
        var paths: Set<String> = []
        if let applicationPath = process(pid: applicationPID)?.path {
            paths.formUnion(Self.cmuxExecutablePathVariants(anchoredAt: applicationPath))
        }
        let bundle = Bundle.main
        if bundle.bundleIdentifier?.localizedCaseInsensitiveContains("cmux") == true,
           let executablePath = bundle.executableURL?.path {
            paths.formUnion(Self.cmuxExecutablePathVariants(anchoredAt: executablePath))
        }
        return Set(paths.compactMap(Self.canonicalExecutablePath))
    }

    /// Lists the app and bundled helper executable paths for one bundle anchor.
    private static func cmuxExecutablePathVariants(anchoredAt path: String) -> Set<String> {
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        var paths: Set<String> = [executableURL.path]
        var current = executableURL
        while current.path != "/" {
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let contents = current.appendingPathComponent("Contents", isDirectory: true)
                for executableName in ["cmux", "cmuxd", "cmux-helper", "cmux-agent"] {
                    paths.insert(contents.appendingPathComponent(
                        "MacOS/\(executableName)",
                        isDirectory: false
                    ).path)
                    paths.insert(contents.appendingPathComponent(
                        "Resources/bin/\(executableName)",
                        isDirectory: false
                    ).path)
                }
                break
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            current = parent
        }
        return paths
    }

    /// Canonicalizes a path for exact executable identity comparison.
    private static func canonicalExecutablePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }
        let canonicalPath = URL(fileURLWithPath: trimmedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return canonicalPath.hasPrefix("/") ? canonicalPath : nil
    }
}
