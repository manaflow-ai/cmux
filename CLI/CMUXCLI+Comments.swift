import Foundation

/// `cmux comments` — read-only access to diff-viewer review comments.
///
/// Strings resolve through `CMUXDiffViewerLocalization`, which reads the enclosing
/// app bundle: the CLI executable carries no string catalog of its own, so
/// `String(localized:)` here would always fall back to its default value.
extension CMUXCLI {
    static let commentsUsage = CMUXDiffViewerLocalization.string(
        "cli.comments.usage",
        defaultValue: """
        Usage: cmux comments <subcommand> [options]

        Review comments saved from the diff viewer, stored per git repository.

        Subcommands:
          list [--repo <path>] [--all] [--json]
            List review comments for a repository (default: the git repository
            containing the current directory). Lists pending comments only;
            --all includes comments already delivered to an agent through a
            TextBox submission.
        """
    )


    static let reviewUsage = String(
        localized: "cli.review.usage",
        defaultValue: """
        Usage: cmux review <subcommand> [options]

        Read local adversarial-review receipts stored in the repository's Git metadata.
        This command does not require a running cmux app or socket.

        Subcommands:
          list [--repo <path>]
              List review runs newest first.
          show [<id|latest>] [--repo <path>]
              Show one review run (default: latest).
          findings [<id|latest>] [--repo <path>] [--all]
              Show findings for one review run. Refuted/suppressed findings are
              hidden unless --all is supplied.

        All subcommands support --json.
        """
    )

    /// `cmux review` reads content-addressed review receipts from Git metadata.
    /// The review skill writes the same format, so the CLI can inspect runs even
    /// when the cmux app and socket are unavailable.
    func runReviewNamespace(
        commandArgs: [String],
        jsonOutput: Bool
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.reviewUsage)
            return
        }

        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: String(
                localized: "cli.review.error.subcommandRequired",
                defaultValue: "review requires a subcommand. Try: list, show, findings"
            ))
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "list", "ls":
            let (repoOption, remainder) = parseOption(rest, name: "--repo")
            try reviewValidateRepoOption(repoOption)
            try reviewRejectUnexpected(remainder, subcommand: "list")
            let ledger = try reviewLedger(startingAt: repoOption ?? FileManager.default.currentDirectoryPath)
            printReviewList(ledger, jsonOutput: jsonOutput)

        case "show":
            let (repoOption, remainder) = parseOption(rest, name: "--repo")
            try reviewValidateRepoOption(repoOption)
            let selector = remainder.first ?? "latest"
            try reviewRejectUnexpected(Array(remainder.dropFirst()), subcommand: "show")
            let ledger = try reviewLedger(startingAt: repoOption ?? FileManager.default.currentDirectoryPath)
            let receipt = try reviewResolveReceipt(selector: selector, receipts: ledger.receipts)
            if jsonOutput {
                print(jsonString(receipt.payload))
            } else {
                printReviewReceipt(receipt)
            }

        case "findings":
            let (repoOption, rem0) = parseOption(rest, name: "--repo")
            try reviewValidateRepoOption(repoOption)
            let includeAll = rem0.contains("--all")
            let positional = rem0.filter { $0 != "--all" }
            let selector = positional.first ?? "latest"
            try reviewRejectUnexpected(Array(positional.dropFirst()), subcommand: "findings")
            let ledger = try reviewLedger(startingAt: repoOption ?? FileManager.default.currentDirectoryPath)
            let receipt = try reviewResolveReceipt(selector: selector, receipts: ledger.receipts)
            printReviewFindings(receipt, includeAll: includeAll, jsonOutput: jsonOutput)

        default:
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.review.error.unknownSubcommand",
                    defaultValue: "Unknown review subcommand '%@'. Try: list, show, findings"
                ),
                sub
            ))
        }
    }

    private struct ReviewReceipt {
        let id: String
        let payload: [String: Any]

        var createdAt: String {
            payload["created_at"] as? String ?? ""
        }

        var source: [String: Any] {
            payload["source"] as? [String: Any] ?? [:]
        }

        var summary: [String: Any] {
            payload["summary"] as? [String: Any] ?? [:]
        }

        var brief: [String: Any] {
            payload["brief"] as? [String: Any] ?? [:]
        }

        var findings: [[String: Any]] {
            payload["findings"] as? [[String: Any]] ?? []
        }
    }

    private struct ReviewLedger {
        let repoRoot: String
        let receipts: [ReviewReceipt]
    }

    private func reviewValidateRepoOption(_ repoOption: String?) throws {
        guard let repoOption else { return }
        if repoOption.hasPrefix("--") {
            throw CLIError(message: String(
                localized: "cli.review.error.repoRequiresPath",
                defaultValue: "--repo requires a path. For a path starting with a dash, pass it as ./-name"
            ))
        }
    }

    private func reviewRejectUnexpected(_ remainder: [String], subcommand: String) throws {
        guard let unexpected = remainder.first else { return }
        throw CLIError(message: String.localizedStringWithFormat(
            String(
                localized: "cli.review.error.unexpectedArgument",
                defaultValue: "Unexpected argument '%1$@' for cmux review %2$@"
            ),
            unexpected,
            subcommand
        ))
    }

    private func reviewGitRepoRoot(startingAt directory: String) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            timeout: 10
        )
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.status == 0, !root.isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.review.error.notARepository",
                    defaultValue: "cmux review requires a git repository: %@"
                ),
                directory
            ))
        }
        return root
    }

    private func reviewDirectoryURL(repoRoot: String) throws -> URL {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "rev-parse", "--git-path", "cmux/reviews"],
            timeout: 10
        )
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.status == 0, !raw.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.review.error.gitMetadataUnavailable",
                defaultValue: "Unable to resolve the repository review ledger path."
            ))
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(raw, isDirectory: true)
            .standardizedFileURL
    }

    private func reviewLedger(startingAt directory: String) throws -> ReviewLedger {
        let repoRoot = try reviewGitRepoRoot(startingAt: directory)
        let reviewDirectory = try reviewDirectoryURL(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: reviewDirectory.path) else {
            return ReviewLedger(repoRoot: repoRoot, receipts: [])
        }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: reviewDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.review.error.readLedger",
                    defaultValue: "Unable to read review ledger: %@"
                ),
                error.localizedDescription
            ))
        }

        var receipts: [ReviewReceipt] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.review.error.readReceipt",
                        defaultValue: "Unable to read review receipt '%1$@': %2$@"
                    ),
                    file.lastPathComponent,
                    error.localizedDescription
                ))
            }

            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["created_at"] is String,
                  payload["source"] is [String: Any],
                  payload["summary"] is [String: Any],
                  payload["findings"] is [[String: Any]] else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.review.error.invalidReceipt",
                        defaultValue: "Invalid cmux review receipt: %@"
                    ),
                    file.lastPathComponent
                ))
            }

            receipts.append(ReviewReceipt(
                id: file.deletingPathExtension().lastPathComponent,
                payload: payload
            ))
        }

        receipts.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id > $1.id
            }
            return $0.createdAt > $1.createdAt
        }
        return ReviewLedger(repoRoot: repoRoot, receipts: receipts)
    }

    private func reviewResolveReceipt(
        selector rawSelector: String,
        receipts: [ReviewReceipt]
    ) throws -> ReviewReceipt {
        guard !receipts.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.review.error.noReceipts",
                defaultValue: "No cmux review receipts found for this repository."
            ))
        }

        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        if selector.isEmpty || selector.lowercased() == "latest" {
            return receipts[0]
        }
        if let exact = receipts.first(where: { $0.id == selector }) {
            return exact
        }
        let prefixMatches = receipts.filter { $0.id.hasPrefix(selector) }
        guard prefixMatches.count == 1, let match = prefixMatches.first else {
            if prefixMatches.count > 1 {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.review.error.ambiguousReceipt",
                        defaultValue: "Review id prefix '%@' is ambiguous."
                    ),
                    selector
                ))
            }
            throw CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.review.error.receiptNotFound",
                    defaultValue: "Review receipt not found: %@"
                ),
                selector
            ))
        }
        return match
    }

    private func reviewInt(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private func reviewShortSHA(_ value: Any?) -> String {
        guard let value = value as? String, !value.isEmpty else { return "?" }
        return String(value.prefix(8))
    }

    private func reviewReceiptSummary(_ receipt: ReviewReceipt) -> [String: Any] {
        let source = receipt.source
        let summary = receipt.summary
        return [
            "id": receipt.id,
            "created_at": receipt.createdAt,
            "base_sha": source["base_sha"] as? String ?? "",
            "head_sha": source["head_sha"] as? String ?? "",
            "working_tree_dirty": source["working_tree_dirty"] as? Bool ?? false,
            "verified": reviewInt(summary["verified"]),
            "human_judgment": reviewInt(summary["human_judgment"]),
            "refuted": reviewInt(summary["refuted"]),
            "suppressed": reviewInt(summary["suppressed"])
        ]
    }

    private func printReviewList(_ ledger: ReviewLedger, jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString([
                "repo_root": ledger.repoRoot,
                "reviews": ledger.receipts.map(reviewReceiptSummary)
            ]))
            return
        }
        guard !ledger.receipts.isEmpty else {
            print(String.localizedStringWithFormat(
                String(
                    localized: "cli.review.list.empty",
                    defaultValue: "No review receipts. (repo: %@)"
                ),
                ledger.repoRoot
            ))
            return
        }

        for receipt in ledger.receipts {
            let source = receipt.source
            let summary = receipt.summary
            let dirty = (source["working_tree_dirty"] as? Bool) == true ? " dirty" : ""
            print(
                "\(receipt.id)  \(receipt.createdAt)  " +
                "\(reviewInt(summary["verified"])) verified · " +
                "\(reviewInt(summary["human_judgment"])) human · " +
                "\(reviewShortSHA(source["base_sha"]))..\(reviewShortSHA(source["head_sha"]))\(dirty)"
            )
        }
    }

    private func printReviewReceipt(_ receipt: ReviewReceipt) {
        let source = receipt.source
        let summary = receipt.summary
        let brief = receipt.brief
        let dirty = (source["working_tree_dirty"] as? Bool) == true ? " (dirty working tree)" : ""
        print("Review \(receipt.id)")
        print("Created: \(receipt.createdAt)")
        print("Source: \(reviewShortSHA(source["base_sha"]))..\(reviewShortSHA(source["head_sha"]))\(dirty)")
        if let policy = receipt.payload["policy_version"] as? String, !policy.isEmpty {
            print("Policy: \(policy)")
        }
        if let intent = brief["intent"] as? String, !intent.isEmpty {
            print("Intent: \(intent)")
        }

        let requirements = brief["requirements"] as? [[String: Any]] ?? []
        if !requirements.isEmpty {
            let satisfied = requirements.filter { ($0["status"] as? String) == "satisfied" }.count
            let missing = requirements.filter { ($0["status"] as? String) == "missing" }.count
            let uncertain = requirements.filter { ($0["status"] as? String) == "uncertain" }.count
            print("Requirements: \(satisfied) satisfied · \(missing) missing · \(uncertain) uncertain")
        }
        print(
            "Findings: \(reviewInt(summary["verified"])) verified · " +
            "\(reviewInt(summary["human_judgment"])) human · " +
            "\(reviewInt(summary["refuted"])) refuted · " +
            "\(reviewInt(summary["suppressed"])) suppressed"
        )
    }

    private func printReviewFindings(
        _ receipt: ReviewReceipt,
        includeAll: Bool,
        jsonOutput: Bool
    ) {
        let findings = receipt.findings.filter { finding in
            guard !includeAll else { return true }
            let disposition = finding["disposition"] as? String ?? ""
            return disposition != "refuted" && disposition != "suppressed"
        }

        if jsonOutput {
            print(jsonString([
                "review_id": receipt.id,
                "findings": findings
            ]))
            return
        }

        guard !findings.isEmpty else {
            print(String(
                localized: "cli.review.findings.empty",
                defaultValue: "No surfaced findings for this review."
            ))
            return
        }

        for finding in findings {
            let id = finding["id"] as? String ?? "?"
            let severity = finding["severity"] as? String ?? "?"
            let title = finding["title"] as? String ?? "Untitled finding"
            let disposition = finding["disposition"] as? String ?? "unresolved"
            let verification = finding["verification"] as? [String: Any]
            let verificationResult = verification?["result"] as? String ?? "unverified"
            print("[\(severity)] \(id)  \(title)")
            print("    \(disposition) · \(verificationResult)")
        }
    }

    /// Runs `cmux comments <subcommand>`; `list` is the only subcommand today.
    /// Rejects anything unrecognized before it resolves a repository or calls the socket.
    func runCommentsNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.commentsUsage)
            return
        }
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.comments.error.subcommandRequired",
                defaultValue: "comments requires a subcommand. Try: list"
            ))
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "list", "ls":
            let (repoOption, remainder) = parseOption(rest, name: "--repo")
            // `parseOption` takes the next token verbatim, so `--repo --all`
            // would resolve a repository named "--all". A path that starts with
            // a dash can still be passed as `./-name`.
            if let repoOption, repoOption.hasPrefix("--") {
                throw CLIError(message: CMUXDiffViewerLocalization.string(
                    "cli.comments.error.repoRequiresPath",
                    defaultValue: "--repo requires a path. For a path starting with a dash, pass it as ./-name"
                ))
            }
            // Fail closed on anything unrecognized: neither a typo like `--al`
            // nor a stray positional may read as a supported request.
            if let unexpected = remainder.first(where: { $0 != "--all" }) {
                throw CLIError(message: String.localizedStringWithFormat(
                    CMUXDiffViewerLocalization.string(
                        "cli.comments.error.unexpectedArgument",
                        defaultValue: "Unexpected argument '%@' for cmux comments list. Supported: --repo <path>, --all, --json"
                    ),
                    unexpected
                ))
            }
            let includeConsumed = remainder.contains("--all")
            let startPath = repoOption ?? FileManager.default.currentDirectoryPath
            var params: [String: Any] = ["repo_root": try commentsGitRepoRoot(startingAt: startPath)]
            if includeConsumed {
                params["include_consumed"] = true
            }
            let payload = try client.sendV2(method: "comments.list", params: params)
            printCommentsListPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string(
                    "cli.comments.error.unknownSubcommand",
                    defaultValue: "Unknown comments subcommand '%@'. Try: list"
                ),
                sub
            ))
        }
    }

    /// Resolves the git top level for `--repo` (or the current directory), so the
    /// socket receives the same canonical root the store is keyed by.
    private func commentsGitRepoRoot(startingAt directory: String) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            timeout: 10
        )
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.status == 0, !root.isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string(
                    "cli.comments.error.notARepository",
                    defaultValue: "cmux comments requires a git repository: %@"
                ),
                directory
            ))
        }
        return root
    }

    /// Builds the count line.
    ///
    /// Selection stays here rather than in catalog plural variations: the count is
    /// resolved before the string is, so a `variations.plural` entry could not see
    /// it. The catalog's non-singular values therefore avoid numeral-governed
    /// nouns, keeping one form grammatical for every count above one in Slavic and
    /// Arabic locales.
    private func commentsListHeaderText(count: Int, repoRoot: String) -> String {
        if count == 1 {
            return String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string(
                    "cli.comments.list.header.one",
                    defaultValue: "1 review comment (repo: %@)"
                ),
                repoRoot
            )
        }
        return String.localizedStringWithFormat(
            CMUXDiffViewerLocalization.string(
                "cli.comments.list.header.other",
                defaultValue: "%1$lld review comments (repo: %2$@)"
            ),
            Int64(count),
            repoRoot
        )
    }

    /// Renders a `comments.list` reply: raw JSON when `--json` is set, otherwise one
    /// line per comment with its anchor text and message.
    private func printCommentsListPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let comments = payload["comments"] as? [[String: Any]] ?? []
        let repoRoot = payload["repo_root"] as? String ?? ""
        guard !comments.isEmpty else {
            print(String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string(
                    "cli.comments.list.empty",
                    defaultValue: "No review comments. (repo: %@)"
                ),
                repoRoot
            ))
            return
        }
        print(commentsListHeaderText(count: comments.count, repoRoot: repoRoot))
        for comment in comments {
            let filePath = comment["filePath"] as? String ?? "?"
            let startLine = intFromAny(comment["startLine"]) ?? 0
            let endLine = intFromAny(comment["endLine"]) ?? startLine
            let range = endLine > startLine ? "\(startLine)-\(endLine)" : "\(startLine)"
            let state = comment["consumedAt"] == nil
                ? CMUXDiffViewerLocalization.string("cli.comments.list.statePending", defaultValue: "pending")
                : CMUXDiffViewerLocalization.string("cli.comments.list.stateConsumed", defaultValue: "consumed")
            print("- \(filePath):\(range) [\(state)]")
            if let lineText = comment["lineText"] as? String, !lineText.isEmpty {
                print(String.localizedStringWithFormat(
                    CMUXDiffViewerLocalization.string(
                        "cli.comments.list.anchor",
                        defaultValue: "    anchor: %@"
                    ),
                    lineText
                ))
            }
            if let message = comment["message"] as? String, !message.isEmpty {
                print("    \(message)")
            }
        }
    }
}
