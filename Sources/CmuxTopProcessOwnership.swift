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
        applicationPID: Int = Int(Darwin.getpid()),
        resolver: CmuxTopProcessOwnershipResolver? = nil
    ) -> CmuxTopMemoryTerminalOwnership {
        let ttyDevice = ttyName.flatMap(Self.deviceIdentifier(forTTYName:))
        return terminalProcessOwnership(
            surfaceID: surfaceID,
            ttyDevice: ttyDevice,
            applicationPID: applicationPID,
            resolver: resolver
        )
    }

    /// Resolves ownership from a device number, keeping tests independent of
    /// the host's live device-node names.
    func terminalProcessOwnership(
        surfaceID: UUID?,
        ttyDevice: Int64?,
        applicationPID: Int = Int(Darwin.getpid()),
        resolver: CmuxTopProcessOwnershipResolver? = nil
    ) -> CmuxTopMemoryTerminalOwnership {
        let ownershipResolver = resolver
            ?? terminalProcessOwnershipResolver(applicationPID: applicationPID)
        return ownershipResolver.resolve(
            surfaceID: surfaceID,
            ttyDevice: ttyDevice
        )
    }

    /// Returns the resolver captured with this snapshot, or builds one from
    /// its immutable process values for manually constructed test snapshots.
    func terminalProcessOwnershipResolver(
        applicationPID: Int = Int(Darwin.getpid())
    ) -> CmuxTopProcessOwnershipResolver {
        terminalOwnershipResolver
            ?? Self.makeTerminalProcessOwnershipResolver(
                processes: Array(processesByPID.values),
                applicationPID: applicationPID
            )
    }

    /// Builds one ownership resolver from a process snapshot's enriched records.
    ///
    /// The application path is read from `records`, after path enrichment has
    /// completed, so helper identity never falls back to a second live process
    /// lookup during annotation.
    static func makeTerminalProcessOwnershipResolver(
        processes: [CmuxTopProcessInfo],
        applicationPID: Int
    ) -> CmuxTopProcessOwnershipResolver {
        let records = processes.map { process in
            CmuxTopMemoryProcessRecord(
                pid: process.pid,
                parentPID: process.parentPID,
                path: process.path,
                ttyDevice: process.ttyDevice,
                workspaceID: process.cmuxWorkspaceID,
                surfaceID: process.cmuxSurfaceID,
                attributionReason: process.cmuxAttributionReason,
                processGroupID: process.processGroupID
            )
        }
        let applicationPath = records.first { $0.pid == applicationPID }?.path
        let trustedPaths = trustedCMUXExecutablePaths(applicationPath: applicationPath)
        return CmuxTopProcessOwnershipResolver(
            processes: records,
            applicationPID: applicationPID,
            trustedExecutablePaths: trustedPaths
        )
    }

    /// Derives trusted helper paths from the captured app path and bundle identity.
    private static func trustedCMUXExecutablePaths(applicationPath: String?) -> Set<String> {
        var paths: Set<String> = []
        if let applicationPath {
            paths.formUnion(cmuxExecutablePathVariants(anchoredAt: applicationPath))
        }
        let bundle = Bundle.main
        if bundle.bundleIdentifier?.localizedCaseInsensitiveContains("cmux") == true,
           let executablePath = bundle.executableURL?.path {
            paths.formUnion(cmuxExecutablePathVariants(anchoredAt: executablePath))
        }
        return paths
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
}
