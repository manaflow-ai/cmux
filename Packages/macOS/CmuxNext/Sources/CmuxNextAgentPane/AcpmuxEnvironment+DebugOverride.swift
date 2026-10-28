#if DEBUG
import Foundation
import os
import CmuxNextCompat

/// DEBUG builds only (Release compiles none of this): `CMUX_NEXT_ACPMUX_BIN=<absolute path>`
/// runs that acpmux instead of the bundled one, so a running DEV build reaches a freshly built
/// daemon without a Swift rebuild.
///
/// It is read from this process's own environment, never from the `environment` a caller passes
/// to ``AcpmuxEnvironment/resolve(build:bundledBinDirectory:environment:userHome:uid:isExecutable:launchEnvironment:)``:
/// the Chief tab and Chief stop resolve with only `ACPMUX_HOME`, and every caller (start, attach,
/// quit, stop, and the server peer check, which compares against ``AcpmuxEnvironment/executable``)
/// must name one binary.
///
/// The path must be absolute and name a regular executable file once symlinks are resolved;
/// anything else is logged and the usual search runs.
nonisolated extension AcpmuxEnvironment {
    static let executableOverrideKey = "CMUX_NEXT_ACPMUX_BIN"

    enum ExecutableOverride: Equatable {
        case unset
        case use(URL)
        case rejected(String)
    }

    /// Pure rule, for tests. `resolveSymlinks` maps a path to its target; `isRegularExecutable`
    /// says whether a resolved path is an executable regular file.
    static func executableOverride(environment: [String: String],
                                   resolveSymlinks: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                                   isRegularExecutable: (String) -> Bool = AcpmuxEnvironment.isRegularExecutableFile)
        -> ExecutableOverride {
        guard let raw = environment[executableOverrideKey], !raw.isEmpty else { return .unset }
        guard raw.hasPrefix("/") else { return .rejected("\(raw) is not an absolute path") }
        let resolved = resolveSymlinks(raw)
        guard isRegularExecutable(resolved) else { return .rejected("\(resolved) is not an executable regular file") }
        return .use(URL(fileURLWithPath: resolved))
    }

    static func isRegularExecutableFile(_ path: String) -> Bool {
        guard let type = (try? FileManager.checked.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
              type == .typeRegular else { return false }
        return FileManager.checked.isExecutableFile(atPath: path)
    }

    /// This process's override, decided and logged once (the first resolve, at startup).
    static let debugExecutableOverride: URL? = {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
        switch executableOverride(environment: ProcessInfo.processInfo.environment) {
        case .unset:
            return nil
        case .use(let url):
            logger.info("acpmux executable=\(url.path, privacy: .public) from \(executableOverrideKey, privacy: .public) (DEBUG override)")
            return url
        case .rejected(let why):
            logger.error("\(executableOverrideKey, privacy: .public) ignored: \(why, privacy: .public); using the usual acpmux search")
            return nil
        }
    }()
}
#endif
