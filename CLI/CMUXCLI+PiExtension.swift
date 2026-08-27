import Foundation
import Darwin

extension CMUXCLI {
    private static let piExtensionMarker = "cmux-pi-session-extension-marker"
    private static let piExtensionFilename = "cmux-session.ts"

    private func piExtensionURL(for def: AgentHookDef) -> URL {
        URL(fileURLWithPath: def.resolvedConfigDir(), isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(Self.piExtensionFilename, isDirectory: false)
    }

    private func existingPiExtensionContents(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let message = String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.error.readFailed",
                    defaultValue: "Failed to read %@"
                ),
                url.path
            )
            throw CLIError(message: message)
        }
    }

    @discardableResult
    private func withPiExtensionMutationLock<T>(
        at extensionURL: URL,
        createParentDirectory: Bool,
        acquireNonBlocking: Bool = false,
        fileManager: FileManager = .default,
        _ operation: () throws -> T
    ) throws -> T? {
        let directoryURL = extensionURL.deletingLastPathComponent()
        if createParentDirectory {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let lockURL = directoryURL.appendingPathComponent(".cmux-session.lock", isDirectory: false)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw piExtensionReadError(at: extensionURL)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw piExtensionReadError(at: extensionURL)
        }
        let lockOperation = LOCK_EX | (acquireNonBlocking ? LOCK_NB : 0)
        guard flock(descriptor, lockOperation) == 0 else {
            if acquireNonBlocking, errno == EWOULDBLOCK || errno == EAGAIN {
                return nil
            }
            throw piExtensionReadError(at: extensionURL)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func piExtensionReadError(at url: URL) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.error.readFailed",
                defaultValue: "Failed to read %@"
            ),
            url.path
        ))
    }

    func refreshManagedPiExtensionIfNeeded(_ def: AgentHookDef) {
        let extensionURL = piExtensionURL(for: def)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: extensionURL.path) else { return }
        do {
            try withPiExtensionMutationLock(
                at: extensionURL,
                createParentDirectory: false,
                acquireNonBlocking: true,
                fileManager: fileManager
            ) {
                guard fileManager.fileExists(atPath: extensionURL.path) else { return }
                let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fileManager)
                if existing.isEmpty {
                    try Self.piExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
                    return
                }
                guard existing.contains(Self.piExtensionMarker),
                      existing != Self.piExtensionSource
                else {
                    return
                }
                // Revalidate immediately before replacement. All cmux install, refresh,
                // and uninstall mutations share this lock, so an in-flight refresh
                // cannot recreate an extension that another cmux process removed.
                guard try existingPiExtensionContents(at: extensionURL, fileManager: fileManager) == existing else {
                    return
                }
                try Self.piExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Hook delivery must continue when a managed extension cannot be refreshed.
        }
    }

    func installPiExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = piExtensionURL(for: def)
        let fileManager = FileManager.default
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fileManager)
        if existing == Self.piExtensionSource {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.alreadyUpToDate",
                    defaultValue: "Pi hooks already up to date at %@"
                ),
                extensionURL.path
            ))
            return
        }
        if !existing.isEmpty, !existing.contains(Self.piExtensionMarker) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.error.notCmuxExtension",
                    defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                ),
                extensionURL.path
            ))
        }
        if !skipConfirm {
            Self.printInstallPreview(
                path: extensionURL.path,
                oldContent: existing,
                newContent: Self.piExtensionSource,
                fallbackContent: Self.piExtensionSource
            )
            print(String(localized: "cli.hooks.pi.confirmProceed", defaultValue: "\nProceed? [y/N] "), terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print(String(localized: "cli.hooks.pi.aborted", defaultValue: "Aborted."))
                return
            }
        }
        try withPiExtensionMutationLock(
            at: extensionURL,
            createParentDirectory: true,
            fileManager: fileManager
        ) {
            let current = try existingPiExtensionContents(at: extensionURL, fileManager: fileManager)
            if !current.isEmpty, !current.contains(Self.piExtensionMarker) {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.hooks.pi.error.notCmuxExtension",
                        defaultValue: "%@ exists and is not a cmux extension; leaving it alone"
                    ),
                    extensionURL.path
                ))
            }
            if current != Self.piExtensionSource {
                try Self.piExtensionSource.write(to: extensionURL, atomically: true, encoding: .utf8)
            }
        }
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.installed",
                defaultValue: "Pi hooks installed at %@"
            ),
            extensionURL.path
        ))
    }

    func uninstallPiExtensionHooks(_ def: AgentHookDef) throws {
        let extensionURL = piExtensionURL(for: def)
        let fm = FileManager.default
        guard fm.fileExists(atPath: extensionURL.path) else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.noneFound",
                    defaultValue: "No Pi cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        var removed = false
        var refused = false
        try withPiExtensionMutationLock(
            at: extensionURL,
            createParentDirectory: false,
            fileManager: fm
        ) {
            let existing = try existingPiExtensionContents(at: extensionURL, fileManager: fm)
            guard !existing.isEmpty else { return }
            guard existing.contains(Self.piExtensionMarker) else {
                refused = true
                return
            }
            try fm.removeItem(at: extensionURL)
            removed = true
        }
        if refused {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.refuseRemoveMissingMarker",
                    defaultValue: "Refusing to remove %@: missing cmux marker"
                ),
                extensionURL.path
            ))
            return
        }
        guard removed else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.hooks.pi.noneFound",
                    defaultValue: "No Pi cmux extension found at %@"
                ),
                extensionURL.path
            ))
            return
        }
        print(String.localizedStringWithFormat(
            String(
                localized: "cli.hooks.pi.removed",
                defaultValue: "Removed Pi cmux extension from %@"
            ),
            extensionURL.path
        ))
    }
}
