import CmuxArtifacts
import Foundation

extension CMUXCLI {
    func runArtifactCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnvironment: [String: String]
    ) async throws {
        let parsed = try artifactArguments(commandArgs)
        let projectRoot = projectFilesProjectRoot(explicitPath: parsed.projectPath)
        let repository = LocalArtifactRepository()
        let terminalText = ArtifactTerminalTextSanitizer()

        do {
            switch parsed.subcommand {
            case "list":
                guard parsed.operands.isEmpty else {
                    throw CLIError(message: artifactUsage(), exitCode: 2)
                }
                let snapshot = try await repository.snapshot(projectRoot: projectRoot)
                let files = snapshot.nodes.flattenedArtifactNodes().filter { !$0.isDirectory }
                if jsonOutput {
                    print(jsonString([
                        "project_root": projectRoot.path,
                        "filesystem_root": snapshot.filesystemRoot.path,
                        "artifacts": files.map(artifactPayload),
                    ]))
                } else if files.isEmpty {
                    print(String(
                        localized: "cli.artifact.output.empty",
                        defaultValue: "No artifacts found."
                    ))
                } else {
                    files.forEach { print(terminalText.sanitize($0.relativePath)) }
                }

            case "path":
                let name = try artifactRequiredOperand(parsed.operands, subcommand: "path")
                let node = try await repository.resolve(projectRoot: projectRoot, name: name)
                if jsonOutput {
                    print(jsonString(artifactPayload(node)))
                } else {
                    print(terminalText.sanitize(node.absolutePath))
                }

            case "open":
                let name = try artifactRequiredOperand(parsed.operands, subcommand: "open")
                let node = try await repository.resolve(projectRoot: projectRoot, name: name)
                try openArtifact(node)
                if jsonOutput { print(jsonString(artifactPayload(node))) }

            case "add":
                let rawPath = try artifactRequiredOperand(parsed.operands, subcommand: "add")
                let sourceURL = projectFilesURL(rawPath)
                let context = try projectFilesCaptureContext(
                    projectRoot: projectRoot,
                    environment: processEnvironment
                )
                let outcome = try await ArtifactCaptureService(store: repository).add(
                    sourceURL: sourceURL,
                    context: context
                )
                guard let record = outcome.record else {
                    guard case .skipped(let reason) = outcome else {
                        throw CLIError(message: String(
                            localized: "cli.artifact.error.addRejected",
                            defaultValue: "The artifact was not added."
                        ))
                    }
                    throw CLIError(message: artifactSkipMessage(reason), exitCode: 2)
                }
                let absolutePath = ArtifactStorePaths(projectRoot: projectRoot).filesystemRoot
                    .appendingPathComponent(record.relativePath, isDirectory: false).path
                if jsonOutput {
                    print(jsonString([
                        "path": absolutePath,
                        "relative_path": record.relativePath,
                        "reference": ".cmux/\(record.relativePath)",
                        "digest": record.digest,
                        "result": artifactOutcomeName(outcome),
                    ]))
                } else {
                    print(terminalText.sanitize(absolutePath))
                }

            case "search":
                let query = try artifactRequiredOperand(parsed.operands, subcommand: "search")
                let results = try await repository.search(projectRoot: projectRoot, query: query)
                if jsonOutput {
                    print(jsonString([
                        "query": query,
                        "results": results.map { result in
                            var payload = artifactPayload(result.node)
                            payload["matched_content"] = result.matchedContent
                            payload["snippet"] = result.snippet ?? NSNull()
                            return payload
                        },
                    ]))
                } else if results.isEmpty {
                    print(String(
                        localized: "cli.artifact.output.noMatches",
                        defaultValue: "No artifacts matched."
                    ))
                } else {
                    for result in results {
                        if let snippet = result.snippet {
                            print(terminalText.sanitize("\(result.node.relativePath): \(snippet)"))
                        } else {
                            print(terminalText.sanitize(result.node.relativePath))
                        }
                    }
                }

            default:
                throw CLIError(message: artifactUsage(), exitCode: 2)
            }
        } catch let error as ArtifactStoreError {
            throw CLIError(
                message: terminalText.sanitize(artifactErrorMessage(error)),
                exitCode: 2
            )
        }
    }

    func artifactUsage() -> String {
        String(localized: "cli.artifact.usage", defaultValue: """
        Usage: cmux artifact list [--project <path>]
               cmux artifact path <name-or-relative-path> [--project <path>]
               cmux artifact open <name-or-relative-path> [--project <path>]
               cmux artifact add <path> [--project <path>]
               cmux artifact search <query> [--project <path>]

        Browse and add ordinary files under agent-session folders in <project>/.cmux.
        Commands work without a running cmux app or socket. The project defaults
        to the nearest ancestor containing .cmux or .git.
        """)
    }

    private func artifactArguments(_ arguments: [String]) throws -> ArtifactCLIArguments {
        var projectPath: String?
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false
        while index < arguments.count {
            let argument = arguments[index]
            if pastTerminator {
                remaining.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if argument == "--project" {
                guard index + 1 < arguments.count else {
                    throw CLIError(message: String(
                        localized: "cli.artifact.error.projectValue",
                        defaultValue: "artifact: --project requires a path"
                    ), exitCode: 2)
                }
                projectPath = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--project=") {
                projectPath = String(argument.dropFirst("--project=".count))
                index += 1
            } else if argument.hasPrefix("-") {
                throw CLIError(message: artifactUsage(), exitCode: 2)
            } else {
                remaining.append(argument)
                index += 1
            }
        }
        if let projectPath,
           projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: String(
                localized: "cli.artifact.error.projectValue",
                defaultValue: "artifact: --project requires a path"
            ), exitCode: 2)
        }
        return ArtifactCLIArguments(
            subcommand: remaining.first?.lowercased() ?? "list",
            operands: Array(remaining.dropFirst()),
            projectPath: projectPath
        )
    }

    private func artifactRequiredOperand(_ operands: [String], subcommand: String) throws -> String {
        let value = operands.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.artifact.error.missingOperand",
                    defaultValue: "artifact %@ requires a value"
                ),
                subcommand
            ), exitCode: 2)
        }
        return value
    }

    private func artifactPayload(_ node: ArtifactNode) -> [String: Any] {
        [
            "name": node.name,
            "relative_path": node.relativePath,
            "path": node.absolutePath,
            "reference": ".cmux/\(node.relativePath)",
            "kind": node.fileKind?.rawValue ?? "other",
            "size": node.size ?? 0,
        ]
    }

    private func artifactOutcomeName(_ outcome: ArtifactImportOutcome) -> String {
        switch outcome {
        case .copied: return "copied"
        case .deduplicated: return "deduplicated"
        case .alreadyStored: return "already_stored"
        case .skipped: return "skipped"
        }
    }

    private func artifactSkipMessage(_ reason: ArtifactSkipReason) -> String {
        switch reason {
        case .automaticCaptureDisabled:
            return String(
                localized: "cli.artifact.error.captureDisabled",
                defaultValue: "Automatic artifact capture is disabled for this project."
            )
        case .provenanceNotEligible:
            return String(
                localized: "cli.artifact.error.provenanceRejected",
                defaultValue: "The file does not meet this project's artifact capture rules."
            )
        case .notARegularFile:
            return String(
                localized: "cli.artifact.error.rejectedNotFile",
                defaultValue: "The artifact path is not a regular file."
            )
        case .pathOutsideStore:
            return String(
                localized: "cli.artifact.error.rejectedOutsideStore",
                defaultValue: "The artifact path escaped the local store."
            )
        case .corruptProvenance:
            return String(
                localized: "cli.artifact.error.rejectedCorruptProvenance",
                defaultValue: "The artifact store's provenance metadata is corrupt."
            )
        case .gitPrivacyUnavailable:
            return String(
                localized: "cli.artifact.error.gitPrivacyUnavailable",
                defaultValue: "Automatic capture paused because Git does not prove the artifact store is ignored and untracked."
            )
        case .storeBusy:
            return String(
                localized: "cli.artifact.error.storeBusy",
                defaultValue: "The artifact store is busy. Try again."
            )
        case .unsupportedExtension:
            return String(
                localized: "cli.artifact.error.rejectedExtension",
                defaultValue: "The file extension is not allowed by this project's artifact settings."
            )
        case .exceedsSizeLimit:
            return String(
                localized: "cli.artifact.error.rejectedSize",
                defaultValue: "The file exceeds this project's artifact size limit."
            )
        case .candidateLimitReached:
            return String(
                localized: "cli.artifact.error.candidateLimit",
                defaultValue: "The artifact capture batch reached its file limit."
            )
        }
    }

    private func openArtifact(_ node: ArtifactNode) throws {
        try openProjectFile(
            path: node.absolutePath,
            failureMessage: String(
                format: String(
                    localized: "cli.artifact.error.openFailed",
                    defaultValue: "Could not open artifact at %@"
                ),
                node.absolutePath
            )
        )
    }

    private func artifactErrorMessage(_ error: ArtifactStoreError) -> String {
        switch error {
        case .sourceNotRegularFile(let path):
            return String(format: String(localized: "cli.artifact.error.notFile", defaultValue: "Not a regular file: %@"), path)
        case .unsupportedExtension(let pathExtension):
            return String(format: String(localized: "cli.artifact.error.unsupported", defaultValue: "Unsupported artifact extension: %@"), pathExtension)
        case .fileTooLarge(let actual, let limit):
            return String(format: String(localized: "cli.artifact.error.tooLarge", defaultValue: "Artifact is too large (%lld bytes; limit %lld)."), actual, limit)
        case .artifactNotFound(let name):
            return String(format: String(localized: "cli.artifact.error.notFound", defaultValue: "Artifact not found: %@"), name)
        case .ambiguousArtifactName(let name, let matches):
            return String(format: String(localized: "cli.artifact.error.ambiguous", defaultValue: "Artifact name '%@' is ambiguous: %@"), name, matches.joined(separator: ", "))
        case .scanIncomplete(let path):
            return String(format: String(localized: "cli.artifact.error.scanIncomplete", defaultValue: "Artifact scan reached its safety limit: %@"), path)
        case .pathOutsideStore(let path):
            return String(format: String(localized: "cli.artifact.error.outsideStore", defaultValue: "Artifact path escaped the store: %@"), path)
        case .corruptProvenance(let path):
            return String(format: String(localized: "cli.artifact.error.corruptProvenance", defaultValue: "Artifact provenance metadata is corrupt: %@"), path)
        case .gitPrivacyUnavailable(let path):
            return String(format: String(localized: "cli.artifact.error.gitPrivacyPath", defaultValue: "Git privacy could not be verified for artifact store: %@"), path)
        case .storeBusy(let path):
            return String(format: String(localized: "cli.artifact.error.storeBusyPath", defaultValue: "Artifact store is busy: %@"), path)
        }
    }
}
