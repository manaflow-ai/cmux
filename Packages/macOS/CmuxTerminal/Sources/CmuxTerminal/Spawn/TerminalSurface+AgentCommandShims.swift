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
    ///   - wrapperDirectoryURL: The app bundle directory containing cmux's launch wrappers.
    ///   - surfaceId: The terminal surface that owns the generated shim directory.
    ///   - temporaryDirectory: The root under which the isolated shim directory is created.
    ///   - hermesProfileAliasDirectoryURL: The Hermes-owned wrapper directory to inspect for profile aliases.
    ///   - fileManager: The filesystem implementation used for discovery and installation.
    /// - Returns: The installed shim set, or `nil` when no bundled wrapper can be installed.
    public static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL?,
        surfaceId: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        hermesProfileAliasDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> TerminalSurfaceAgentCommandShimSet? {
        guard let wrapperDirectoryURL = wrapperDirectoryURL?.standardizedFileURL else { return nil }
        let aliases = hermesProfileAliasDirectoryURL.map { aliasDirectoryURL in
            HermesProfileAliasResolver(
                wrapperDirectoryURL: aliasDirectoryURL,
                fileManager: fileManager
            ).resolve(excluding: reservedAgentCommandShimNames)
        } ?? []
        return installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectoryURL,
            surfaceId: surfaceId,
            temporaryDirectory: temporaryDirectory,
            hermesProfileAliases: aliases,
            fileManager: fileManager
        )
    }

    /// Writes bundled agent shims using a process-owned Hermes alias catalog.
    ///
    /// The catalog serializes concurrent restore requests and scans the shared
    /// Hermes wrapper directory only once per directory generation.
    ///
    /// - Parameters:
    ///   - wrapperDirectoryURL: The app bundle directory containing cmux's launch wrappers.
    ///   - surfaceId: The terminal surface that owns the generated shim directory.
    ///   - temporaryDirectory: The root under which the isolated shim directory is created.
    ///   - hermesProfileAliasCatalog: The process-owned Hermes alias discovery cache.
    ///   - fileManager: The filesystem implementation used for shim installation.
    /// - Returns: The installed shim set, or `nil` when no bundled wrapper can be installed.
    public static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL?,
        surfaceId: UUID,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        hermesProfileAliasCatalog: HermesProfileAliasCatalog,
        fileManager: FileManager = .default
    ) async -> TerminalSurfaceAgentCommandShimSet? {
        guard let wrapperDirectoryURL = wrapperDirectoryURL?.standardizedFileURL else { return nil }
        let aliases = await hermesProfileAliasCatalog.aliases(
            excluding: reservedAgentCommandShimNames
        )
        return installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectoryURL,
            surfaceId: surfaceId,
            temporaryDirectory: temporaryDirectory,
            hermesProfileAliases: aliases,
            fileManager: fileManager
        )
    }

    private static var reservedAgentCommandShimNames: Set<String> {
        Set(TerminalSurfaceAgentCommandShimDefinition.bundled.map(\.commandName))
    }

    private static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL,
        surfaceId: UUID,
        temporaryDirectory: URL,
        hermesProfileAliases: [HermesProfileAliasResolver.Alias],
        fileManager: FileManager
    ) -> TerminalSurfaceAgentCommandShimSet? {
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
        do {
            try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
            for directory in [shimParentDirectory, shimDirectory] {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        } catch {
            return nil
        }

        var shims: [TerminalSurfaceAgentCommandShim] = []
        if let hermesDefinition = availableDefinitions.first(where: {
            $0.definition.commandName == "hermes"
        }) {
            for alias in hermesProfileAliases {
                guard let shim = installAgentCommandShim(
                    definition: hermesDefinition.definition,
                    commandName: alias.commandName,
                    hermesProfileAliasURL: URL(
                        fileURLWithPath: alias.wrapperPath,
                        isDirectory: false
                    ),
                    wrapperURL: hermesDefinition.wrapperURL,
                    shimDirectory: shimDirectory,
                    fileManager: fileManager
                ) else { continue }
                shims.append(shim)
            }
        }
        for (definition, wrapperURL) in availableDefinitions {
            guard let shim = installAgentCommandShim(
                definition: definition,
                wrapperURL: wrapperURL,
                shimDirectory: shimDirectory,
                fileManager: fileManager
            ) else { continue }
            shims.append(shim)
        }
        guard !shims.isEmpty else { return nil }
        return TerminalSurfaceAgentCommandShimSet(
            directoryPath: shimDirectory.path,
            shims: shims
        )
    }

    private static func installAgentCommandShim(
        definition: TerminalSurfaceAgentCommandShimDefinition,
        commandName: String? = nil,
        hermesProfileAliasURL: URL? = nil,
        wrapperURL: URL,
        shimDirectory: URL,
        fileManager: FileManager
    ) -> TerminalSurfaceAgentCommandShim? {
        let commandName = commandName ?? definition.commandName
        let shimURL = shimDirectory.appendingPathComponent(commandName, isDirectory: false)
        let wrapperInvocation: String
        if let hermesProfileAliasURL {
            // Hermes owns and can retarget this two-line wrapper while the
            // terminal remains open. Revalidate its bounded canonical form on
            // every invocation instead of freezing a profile into the shim.
            wrapperInvocation = """
            cmux_alias_path=\(shellSingleQuoted(hermesProfileAliasURL.path))
            cmux_alias_contents=""
            if [[ -f "$cmux_alias_path" && -x "$cmux_alias_path" ]]; then
                IFS= read -r -d '' -n 2049 cmux_alias_contents < "$cmux_alias_path" || true
                if (( ${#cmux_alias_contents} <= 2048 )); then
                    cmux_alias_contents="${cmux_alias_contents//$'\\r\\n'/$'\\n'}"
                    if [[ "$cmux_alias_contents" == *$'\\n' ]]; then
                        cmux_alias_contents="${cmux_alias_contents%$'\\n'}"
                    fi
                    if [[ "$cmux_alias_contents" == *$'\\n'* ]]; then
                        cmux_alias_header="${cmux_alias_contents%%$'\\n'*}"
                        cmux_alias_line="${cmux_alias_contents#*$'\\n'}"
                        cmux_alias_argument_suffix=' "$@"'
                        if [[ "$cmux_alias_header" == '#!/bin/sh' &&
                              "$cmux_alias_line" != *$'\\n'* &&
                              "$cmux_alias_line" == exec\\ *"$cmux_alias_argument_suffix" ]]; then
                            cmux_alias_command="${cmux_alias_line#exec }"
                            cmux_alias_command="${cmux_alias_command%"$cmux_alias_argument_suffix"}"
                            if [[ "$cmux_alias_command" == *" -p "* ]]; then
                                cmux_alias_profile="${cmux_alias_command##* -p }"
                                cmux_alias_executable="${cmux_alias_command% -p *}"
                                cmux_alias_resolved_executable="$cmux_alias_executable"
                                if [[ "${cmux_alias_executable:0:1}" == "'" &&
                                      "${cmux_alias_executable: -1}" == "'" ]]; then
                                    cmux_alias_resolved_executable="${cmux_alias_executable:1:${#cmux_alias_executable}-2}"
                                elif [[ "$cmux_alias_executable" == *[[:space:]]* ]]; then
                                    cmux_alias_resolved_executable=""
                                fi
                                if [[ "$cmux_alias_profile" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ &&
                                      "${cmux_alias_resolved_executable##*/}" == "hermes" ]]; then
                                    exec "$cmux_wrapper" -p "$cmux_alias_profile" "$@"
                                fi
                            fi
                        fi
                    fi
                fi
            fi
            """
        } else {
            wrapperInvocation = "exec \"$cmux_wrapper\" \"$@\""
        }
        let script = """
        #!/bin/bash
        cmux_wrapper=\(shellSingleQuoted(wrapperURL.path))
        cmux_shim_root=\(shellSingleQuoted(shimDirectory.path))
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
        export \(definition.environmentVariablePrefix)_WRAPPER_SHIM=\(shellSingleQuoted(shimURL.path))
        export \(definition.environmentVariablePrefix)_WRAPPER_SHIM_ROOT="$cmux_shim_root"
        if [[ -x "$cmux_wrapper" ]]; then
            \(wrapperInvocation)
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
        exec \(shellSingleQuoted(commandName)) "$@"
        """

        do {
            try script.write(to: shimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimURL.path)
            return TerminalSurfaceAgentCommandShim(
                commandName: commandName,
                wrapperName: definition.wrapperName,
                environmentVariablePrefix: definition.environmentVariablePrefix,
                directoryPath: shimDirectory.path,
                executablePath: shimURL.path
            )
        } catch {
            return nil
        }
    }
}
