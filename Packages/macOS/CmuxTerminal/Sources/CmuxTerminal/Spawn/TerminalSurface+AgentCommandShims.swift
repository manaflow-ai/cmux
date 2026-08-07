public import Foundation
public import CmuxTerminalCore

extension TerminalSurface {
    /// Writes every available bundled agent wrapper shim into one per-surface directory.
    ///
    /// Adding an agent to ``TerminalSurfaceAgentCommandShimDefinition/bundled``
    /// automatically gives it the same lifecycle, permissions, `PATH`, bundle-
    /// replacement fallback, and environment behavior as existing agents.
    ///
    /// - Parameters:
    ///   - wrapperDirectoryURL: The app resource directory containing bundled wrappers.
    ///   - surfaceId: The terminal surface that owns the generated shim directory.
    ///   - temporaryDirectory: The root used for generated shim directories.
    ///   - fileManager: The filesystem implementation used to install the shims.
    /// - Returns: The installed shim set, or `nil` when no wrapper is available.
    public static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL?,
        surfaceId: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> TerminalSurfaceAgentCommandShimSet? {
        guard let wrapperDirectoryURL = wrapperDirectoryURL?.standardizedFileURL else {
            return nil
        }

        var availableDefinitions: [(
            definition: TerminalSurfaceAgentCommandShimDefinition,
            wrapperURL: URL
        )] = []
        for definition in TerminalSurfaceAgentCommandShimDefinition.bundled {
            let wrapperURL = wrapperDirectoryURL
                .appendingPathComponent(definition.wrapperName, isDirectory: false)
                .standardizedFileURL
            guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { continue }
            availableDefinitions.append((definition, wrapperURL))
        }
        guard !availableDefinitions.isEmpty else { return nil }

        let shimParentDirectory = temporaryDirectory
            .appendingPathComponent("cmux-cli-shims", isDirectory: true)
            .standardizedFileURL
        let shimDirectory = shimParentDirectory
            .appendingPathComponent(surfaceId.uuidString, isDirectory: true)
            .standardizedFileURL
        let stagingDirectory = shimParentDirectory
            .appendingPathComponent(".\(surfaceId.uuidString).staging.\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }
        do {
            try fileManager.createDirectory(at: shimParentDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            for directory in [shimParentDirectory, stagingDirectory] {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        } catch {
            return nil
        }

        var shims: [TerminalSurfaceAgentCommandShim] = []
        for (definition, wrapperURL) in availableDefinitions {
            guard let shim = installAgentCommandShim(
                definition: definition,
                wrapperURL: wrapperURL,
                stagingDirectory: stagingDirectory,
                publishedDirectory: shimDirectory,
                fileManager: fileManager
            ) else { continue }
            shims.append(shim)
        }
        guard !shims.isEmpty else { return nil }
        do {
            if fileManager.fileExists(atPath: shimDirectory.path) {
                _ = try fileManager.replaceItemAt(
                    shimDirectory,
                    withItemAt: stagingDirectory,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: shimDirectory)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimDirectory.path)
        } catch {
            return nil
        }
        return TerminalSurfaceAgentCommandShimSet(
            directoryPath: shimDirectory.path,
            shims: shims
        )
    }

    private static func installAgentCommandShim(
        definition: TerminalSurfaceAgentCommandShimDefinition,
        wrapperURL: URL,
        stagingDirectory: URL,
        publishedDirectory: URL,
        fileManager: FileManager
    ) -> TerminalSurfaceAgentCommandShim? {
        let stagingShimURL = stagingDirectory
            .appendingPathComponent(definition.commandName, isDirectory: false)
        let publishedShimURL = publishedDirectory
            .appendingPathComponent(definition.commandName, isDirectory: false)
        let script = """
        #!/usr/bin/env bash
        cmux_wrapper=\(shellSingleQuoted(wrapperURL.path))
        cmux_shim_root=\(shellSingleQuoted(publishedDirectory.path))
        if [[ ! -x "$cmux_wrapper" && -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then
            cmux_candidate="$(dirname "$CMUX_BUNDLED_CLI_PATH")/\(definition.wrapperName)"
            if [[ -x "$cmux_candidate" ]]; then
                cmux_wrapper="$cmux_candidate"
            fi
        fi
        if [[ ! -x "$cmux_wrapper" ]]; then
            cmux_cli="$(command -v cmux 2>/dev/null || true)"
            if [[ -n "$cmux_cli" ]]; then
                cmux_candidate="$(dirname "$cmux_cli")/\(definition.wrapperName)"
                if [[ -x "$cmux_candidate" ]]; then
                    cmux_wrapper="$cmux_candidate"
                fi
            fi
        fi
        export \(definition.environmentVariablePrefix)_WRAPPER_SHIM=\(shellSingleQuoted(publishedShimURL.path))
        export \(definition.environmentVariablePrefix)_WRAPPER_SHIM_ROOT="$cmux_shim_root"
        if [[ -x "$cmux_wrapper" ]]; then
            exec "$cmux_wrapper" "$@"
        fi
        cmux_path_without_shim=""
        cmux_old_ifs="$IFS"
        cmux_globbing_was_disabled=0
        case "$-" in
            *f*) cmux_globbing_was_disabled=1 ;;
            *) set -f ;;
        esac
        IFS=:
        for cmux_entry in ${PATH:-}; do
            if [[ "$cmux_entry" == "$cmux_shim_root" || "$cmux_entry" == */cmux-cli-shims/* || "$cmux_entry" == */cmux-cli-shims ]]; then
                continue
            fi
            if [[ -z "$cmux_path_without_shim" ]]; then
                cmux_path_without_shim="$cmux_entry"
            else
                cmux_path_without_shim="$cmux_path_without_shim:$cmux_entry"
            fi
        done
        IFS="$cmux_old_ifs"
        if [[ "$cmux_globbing_was_disabled" == 0 ]]; then
            set +f
        fi
        export PATH="$cmux_path_without_shim"
        exec \(shellSingleQuoted(definition.commandName)) "$@"
        """

        do {
            try script.write(to: stagingShimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingShimURL.path)
            return TerminalSurfaceAgentCommandShim(
                commandName: definition.commandName,
                wrapperName: definition.wrapperName,
                environmentVariablePrefix: definition.environmentVariablePrefix,
                directoryPath: publishedDirectory.path,
                executablePath: publishedShimURL.path
            )
        } catch {
            return nil
        }
    }
}
