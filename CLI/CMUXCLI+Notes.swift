import CmuxArtifacts
import Foundation

extension CMUXCLI {
    func runNoteCommand(
        commandArgs: [String],
        jsonOutput: Bool,
        processEnvironment: [String: String]
    ) async throws {
        let parsed = try noteArguments(commandArgs)
        let projectRoot = projectFilesProjectRoot(explicitPath: parsed.projectPath)
        let repository = LocalArtifactRepository()
        let terminalText = ArtifactTerminalTextSanitizer()

        do {
            switch parsed.subcommand {
            case "list":
                guard parsed.operands.isEmpty else { throw noteUsageError() }
                let notes = try await repository.listNotes(projectRoot: projectRoot)
                if jsonOutput {
                    print(jsonString([
                        "project_root": projectRoot.path,
                        "filesystem_root": ArtifactStorePaths(projectRoot: projectRoot).filesystemRoot.path,
                        "notes": notes.map(notePayload),
                    ]))
                } else if notes.isEmpty {
                    print(String(localized: "cli.note.output.empty", defaultValue: "No notes found."))
                } else {
                    notes.forEach { print(terminalText.sanitize($0.relativePath)) }
                }

            case "path":
                let name = try noteRequiredOperand(parsed.operands, subcommand: "path")
                let note = try await repository.resolveNote(projectRoot: projectRoot, name: name)
                if jsonOutput {
                    print(jsonString(notePayload(note)))
                } else {
                    print(terminalText.sanitize(note.absolutePath))
                }

            case "read":
                let name = try noteRequiredOperand(parsed.operands, subcommand: "read")
                let note = try await repository.resolveNote(projectRoot: projectRoot, name: name)
                let text = try await repository.readNote(projectRoot: projectRoot, name: note.relativePath)
                if jsonOutput {
                    var payload = notePayload(note)
                    payload["text"] = text
                    print(jsonString(payload))
                } else {
                    try FileHandle.standardOutput.write(
                        contentsOf: Data(terminalText.sanitizeTextContent(text).utf8)
                    )
                }

            case "write", "append":
                let name = try noteRequiredOperand(parsed.operands, subcommand: parsed.subcommand)
                let text = try noteInput(parsed)
                let note = try await repository.writeNote(
                    name: name,
                    text: text,
                    mode: parsed.subcommand == "append" ? .append : .replace,
                    context: projectFilesCaptureContext(
                        projectRoot: projectRoot,
                        environment: processEnvironment
                    )
                )
                if jsonOutput {
                    print(jsonString(notePayload(note)))
                } else {
                    print(terminalText.sanitize(note.absolutePath))
                }

            case "search":
                let query = try noteRequiredOperand(parsed.operands, subcommand: "search")
                let results = try await repository.searchNotes(projectRoot: projectRoot, query: query)
                if jsonOutput {
                    print(jsonString([
                        "query": query,
                        "results": results.map { result in
                            var payload = notePayload(result.note)
                            payload["matched_content"] = result.matchedContent
                            payload["snippet"] = result.snippet ?? NSNull()
                            return payload
                        },
                    ]))
                } else if results.isEmpty {
                    print(String(localized: "cli.note.output.noMatches", defaultValue: "No notes matched."))
                } else {
                    results.forEach { result in
                        let line = result.snippet.map { "\(result.note.relativePath): \($0)" }
                            ?? result.note.relativePath
                        print(terminalText.sanitize(line))
                    }
                }

            case "open":
                let name = try noteRequiredOperand(parsed.operands, subcommand: "open")
                let note = try await repository.resolveNote(projectRoot: projectRoot, name: name)
                try openProjectFile(
                    path: note.absolutePath,
                    failureMessage: String(
                        format: String(
                            localized: "cli.note.error.openFailed",
                            defaultValue: "Could not open note at %@"
                        ),
                        note.absolutePath
                    )
                )
                if jsonOutput { print(jsonString(notePayload(note))) }

            case "rm", "delete":
                let name = try noteRequiredOperand(parsed.operands, subcommand: "rm")
                let note = try await repository.resolveNote(projectRoot: projectRoot, name: name)
                try await repository.deleteNote(projectRoot: projectRoot, name: note.relativePath)
                if jsonOutput {
                    print(jsonString(notePayload(note)))
                } else {
                    print(terminalText.sanitize(String(
                        format: String(
                            localized: "cli.note.output.deleted",
                            defaultValue: "Deleted %@"
                        ),
                        note.reference
                    )))
                }

            default:
                throw noteUsageError()
            }
        } catch let error as CmuxNoteStoreError {
            throw CLIError(message: terminalText.sanitize(noteErrorMessage(error)), exitCode: 2)
        } catch let error as ArtifactStoreError {
            throw CLIError(message: terminalText.sanitize(noteArtifactErrorMessage(error)), exitCode: 2)
        }
    }

    func noteUsage() -> String {
        String(localized: "cli.note.usage", defaultValue: """
        Usage: cmux note list [--project <path>]
               cmux note path <name-or-relative-path> [--project <path>]
               cmux note read <name-or-relative-path> [--project <path>]
               cmux note write <name> (--text <text>|--stdin) [--project <path>]
               cmux note append <name> (--text <text>|--stdin) [--project <path>]
               cmux note search <query> [--project <path>]
               cmux note open <name-or-relative-path> [--project <path>]
               cmux note rm <name-or-relative-path> [--project <path>]

        Read and write ordinary Markdown files under the current agent session's
        <project>/.cmux/<agent-session>/notes directory. Commands work without a
        running cmux app or socket. Existing notes are rediscovered after moves.
        """)
    }

    private func noteArguments(_ arguments: [String]) throws -> NoteCLIArguments {
        var projectPath: String?
        var text: String?
        var readsStandardInput = false
        var remaining: [String] = []
        var index = 0
        var pastTerminator = false
        while index < arguments.count {
            let argument = arguments[index]
            if pastTerminator {
                remaining.append(argument)
                index += 1
            } else if argument == "--" {
                pastTerminator = true
                index += 1
            } else if argument == "--project" || argument == "--text" {
                guard index + 1 < arguments.count else { throw noteUsageError() }
                if argument == "--project" { projectPath = arguments[index + 1] }
                else { text = arguments[index + 1] }
                index += 2
            } else if argument.hasPrefix("--project=") {
                projectPath = String(argument.dropFirst("--project=".count))
                index += 1
            } else if argument.hasPrefix("--text=") {
                text = String(argument.dropFirst("--text=".count))
                index += 1
            } else if argument == "--stdin" {
                readsStandardInput = true
                index += 1
            } else if argument.hasPrefix("-") {
                throw noteUsageError()
            } else {
                remaining.append(argument)
                index += 1
            }
        }
        if let projectPath,
           projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: String(
                localized: "cli.note.error.projectValue",
                defaultValue: "note: --project requires a path"
            ), exitCode: 2)
        }
        return NoteCLIArguments(
            subcommand: remaining.first?.lowercased() ?? "list",
            operands: Array(remaining.dropFirst()),
            projectPath: projectPath,
            text: text,
            readsStandardInput: readsStandardInput
        )
    }

    private func noteInput(_ arguments: NoteCLIArguments) throws -> String {
        guard (arguments.text == nil) != arguments.readsStandardInput else {
            throw CLIError(message: String(
                localized: "cli.note.error.input",
                defaultValue: "note write and append require exactly one of --text or --stdin"
            ), exitCode: 2)
        }
        if let text = arguments.text { return text }
        let maximumBytes = 4 * 1024 * 1024
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(64 * 1024, remaining)
            ), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw CLIError(message: String(
                localized: "cli.note.error.inputTooLarge",
                defaultValue: "Note input exceeds the 4 MiB limit."
            ), exitCode: 2)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: String(
                localized: "cli.note.error.inputUTF8",
                defaultValue: "Note input must be valid UTF-8."
            ), exitCode: 2)
        }
        return text
    }

    private func noteRequiredOperand(_ operands: [String], subcommand: String) throws -> String {
        let value = operands.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.note.error.missingOperand",
                    defaultValue: "note %@ requires a value"
                ),
                subcommand
            ), exitCode: 2)
        }
        return value
    }

    private func notePayload(_ note: CmuxProjectNote) -> [String: Any] {
        [
            "name": note.name,
            "relative_path": note.relativePath,
            "path": note.absolutePath,
            "reference": note.reference,
            "size": note.size ?? 0,
        ]
    }

    private func noteUsageError() -> CLIError {
        CLIError(message: noteUsage(), exitCode: 2)
    }

    private func noteErrorMessage(_ error: CmuxNoteStoreError) -> String {
        switch error {
        case .invalidName(let name):
            return String(format: String(localized: "cli.note.error.invalidName", defaultValue: "Invalid note name: %@"), name)
        case .noteNotFound(let name):
            return String(format: String(localized: "cli.note.error.notFound", defaultValue: "Note not found: %@"), name)
        case .ambiguousNoteName(let name, let matches):
            return String(format: String(localized: "cli.note.error.ambiguous", defaultValue: "Note name '%@' is ambiguous: %@"), name, matches.joined(separator: ", "))
        case .invalidUTF8(let path):
            return String(format: String(localized: "cli.note.error.invalidUTF8", defaultValue: "Note is not valid UTF-8: %@"), path)
        case .noteTooLarge(let actual, let limit):
            return String(format: String(localized: "cli.note.error.tooLarge", defaultValue: "Note is too large (%lld bytes; limit %lld)."), actual, limit)
        case .pathOutsideStore(let path):
            return String(format: String(localized: "cli.note.error.outsideStore", defaultValue: "Note path escaped the store: %@"), path)
        }
    }

    private func noteArtifactErrorMessage(_ error: ArtifactStoreError) -> String {
        switch error {
        case .storeBusy(let path):
            return String(format: String(localized: "cli.note.error.storeBusy", defaultValue: "Notes store is busy: %@"), path)
        case .scanIncomplete(let path):
            return String(format: String(localized: "cli.note.error.scanIncomplete", defaultValue: "Notes scan reached its safety limit: %@"), path)
        case .pathOutsideStore(let path):
            return String(format: String(localized: "cli.note.error.outsideStore", defaultValue: "Note path escaped the store: %@"), path)
        default:
            return String(localized: "cli.note.error.store", defaultValue: "The Notes filesystem could not be updated.")
        }
    }
}
