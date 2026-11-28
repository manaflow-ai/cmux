import CmuxFoundation
import Darwin
import Foundation

extension CMUXCLI {
    static var glaedaUsage: String {
        CmuxGlaedaExecutionLocalization().string(
            "glaeda.cli.usage",
            defaultValue: """
            Usage: cmux glaeda <request|observe> [options]

            Exchange one semantic execution request with the execution service.

            Subcommands:
              request
                --request-ref <ref>        CMUX caller correlation reference
                --work-ref <ref>           CMUX work correlation reference
                --repository <owner/repo>  Canonical Git repository identity
                --commit <40-hex>          Exact Git commit
                --tree <40-hex>            Exact Git tree
                [--reuse <prefer_valid_reuse|no_preference>]

                Emits canonical execution-request JSON to stdout.
                CMUX workspace, machine, shell command, and environment stay outside this request.

              observe
                --request <path>           Exact request document previously emitted
                --receipt <path|->         Bounded execution receipt, or - for stdin

                Validates request/result correlation and emits a bounded CMUX observation.
                Terminal states require a workload-receipt digest.

            Examples:
              cmux glaeda request --request-ref cmux:exec:42 --work-ref cmux:work:42 \
                --repository owner/repo --commit <commit> --tree <tree>
              cmux glaeda observe --request request.json --receipt result.json
            """
        )
    }

    func runGlaedaCommand(commandArgs: [String]) throws {
        let localization = CmuxGlaedaExecutionLocalization()
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: Self.glaedaUsage)
        }
        let rest = Array(commandArgs.dropFirst())
        do {
            switch subcommand {
            case "request":
                let request = try glaedaRequest(arguments: rest, localization: localization)
                let data = try CmuxGlaedaExecutionContract().encodeRequest(request)
                cliWriteStdout(data)
            case "observe":
                let observation = try glaedaObservation(
                    arguments: rest,
                    localization: localization
                )
                let data = try CmuxGlaedaExecutionContract().encodeObservation(observation)
                cliWriteStdout(data)
            case "help", "--help", "-h":
                guard rest.isEmpty else {
                    throw CLIError(
                        message: localization.string(
                            "glaeda.cli.error.helpArguments",
                            defaultValue: "This help command accepts no additional arguments."
                        )
                    )
                }
                cliWriteStdout(Self.glaedaUsage + "\n")
            default:
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.unknownSubcommand",
                        defaultValue: "Unknown execution subcommand: %@",
                        subcommand
                    ) + "\n\n" + Self.glaedaUsage
                )
            }
        } catch let error as CmuxGlaedaExecutionContractError {
            throw CLIError(message: localization.contractError(error))
        }
    }

    private func glaedaRequest(
        arguments: [String],
        localization: CmuxGlaedaExecutionLocalization
    ) throws -> CmuxGlaedaExecutionRequest {
        let options = try glaedaParseOptions(
            arguments,
            allowed: [
                "--request-ref",
                "--work-ref",
                "--repository",
                "--commit",
                "--tree",
                "--reuse",
            ],
            localization: localization
        )
        return CmuxGlaedaExecutionRequest(
            externalRequestRef: try glaedaRequiredOption(
                "--request-ref",
                options: options,
                localization: localization
            ),
            workRef: try glaedaRequiredOption(
                "--work-ref",
                options: options,
                localization: localization
            ),
            repository: try glaedaRequiredOption(
                "--repository",
                options: options,
                localization: localization
            ),
            commit: try glaedaRequiredOption(
                "--commit",
                options: options,
                localization: localization
            ),
            tree: try glaedaRequiredOption(
                "--tree",
                options: options,
                localization: localization
            ),
            reuseHint: options["--reuse"] ?? "prefer_valid_reuse"
        )
    }

    private func glaedaObservation(
        arguments: [String],
        localization: CmuxGlaedaExecutionLocalization
    ) throws -> CmuxGlaedaExecutionObservation {
        let options = try glaedaParseOptions(
            arguments,
            allowed: ["--request", "--receipt"],
            localization: localization
        )
        let requestPath = try glaedaRequiredOption(
            "--request",
            options: options,
            localization: localization
        )
        let receiptPath = try glaedaRequiredOption(
            "--receipt",
            options: options,
            localization: localization
        )
        let requestData = try glaedaReadDocument(
            path: requestPath,
            localization: localization
        )
        let receiptData = try glaedaReadDocument(
            path: receiptPath,
            localization: localization
        )
        return try CmuxGlaedaExecutionContract().observe(
            requestData: requestData,
            receiptData: receiptData
        )
    }

    private func glaedaParseOptions(
        _ arguments: [String],
        allowed: Set<String>,
        localization: CmuxGlaedaExecutionLocalization
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.unknownOption",
                        defaultValue: "Unknown option: %@",
                        option
                    )
                )
            }
            guard result[option] == nil else {
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.duplicateOption",
                        defaultValue: "%@ may only be supplied once.",
                        option
                    )
                )
            }
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.optionValueRequired",
                        defaultValue: "%@ requires a value.",
                        option
                    )
                )
            }
            result[option] = arguments[index]
            index += 1
        }
        return result
    }

    private func glaedaRequiredOption(
        _ key: String,
        options: [String: String],
        localization: CmuxGlaedaExecutionLocalization
    ) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw CLIError(
                message: localization.format(
                    "glaeda.cli.error.missingOption",
                    defaultValue: "Missing required option: %@",
                    key
                )
            )
        }
        return value
    }

    private func glaedaReadDocument(
        path: String,
        localization: CmuxGlaedaExecutionLocalization
    ) throws -> Data {
        if path == "-" {
            let data = FileHandle.standardInput.readData(
                ofLength: CmuxGlaedaExecutionContract.maxDocumentBytes + 1
            )
            guard data.count <= CmuxGlaedaExecutionContract.maxDocumentBytes else {
                throw CLIError(
                    message: localization.string(
                        "glaeda.cli.error.documentTooLarge",
                        defaultValue: "The input document exceeds the size limit."
                    )
                )
            }
            return data
        }

        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.documentUnavailable",
                    defaultValue: "The input document is unavailable."
                )
            )
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.regularFileRequired",
                    defaultValue: "The input document must be a regular file."
                )
            )
        }

        let limit = CmuxGlaedaExecutionContract.maxDocumentBytes + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(1024, limit))
        while data.count < limit {
            let count = min(buffer.count, limit - data.count)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, count)
            }
            if readCount > 0 {
                data.append(buffer, count: readCount)
                continue
            }
            if readCount == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.documentUnavailable",
                    defaultValue: "The input document is unavailable."
                )
            )
        }

        guard data.count <= CmuxGlaedaExecutionContract.maxDocumentBytes else {
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.documentTooLarge",
                    defaultValue: "The input document exceeds the size limit."
                )
            )
        }
        return data
    }
}
