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


    static let reviewUsage = CMUXDiffViewerLocalization.string(
        "cli.review.usage",
        defaultValue: """
        Usage: cmux review <subcommand> [options]

        Review a frozen diff; tools and repairs are disabled.
        Running reviews requires a signed-in Codex CLI.
        Model claims still require executable verification.

          run --intent <task> [--base <ref>] [--reviewer <executable>]
          list
          show [<id|latest>]
          findings [<id|latest>] [--all]

        All subcommands accept --repo <path> and --json.
        No running cmux app or socket is required.
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
        case "run":
            try runReview(commandArgs: rest, jsonOutput: jsonOutput)

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
        let createdAtDate: Date

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

    func reviewGitRepoRoot(startingAt directory: String) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ReviewCandidate.gitEnvironmentArguments() + ["git", "-C", directory, "rev-parse", "--show-toplevel"],
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

    func reviewDirectoryURL(repoRoot: String) throws -> URL {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ReviewCandidate.gitEnvironmentArguments() + ["git", "-C", repoRoot, "rev-parse", "--git-path", "cmux/reviews"],
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

    func reviewValidateReceiptPayload(
        _ payload: [String: Any],
        fileName: String
    ) throws -> Date {
        func invalid(_ detail: String) -> CLIError {
            CLIError(message: String.localizedStringWithFormat(
                String(
                    localized: "cli.review.error.invalidReceiptDetail",
                    defaultValue: "Invalid cmux review receipt '%1$@': %2$@"
                ),
                fileName,
                detail
            ))
        }

        let expectedTopLevel: Set<String> = [
            "schema_version",
            "policy_version",
            "repository_root",
            "ruleset_sha256",
            "source",
            "brief",
            "summary",
            "findings",
            "created_at"
        ]
        guard Set(payload.keys) == expectedTopLevel else {
            throw invalid("unexpected or missing top-level fields")
        }
        guard reviewInt(payload["schema_version"]) == 1 else {
            throw invalid("schema_version must be 1")
        }
        guard reviewNonemptyString(payload["policy_version"]) != nil else {
            throw invalid("policy_version must be a non-empty string")
        }
        guard reviewNonemptyString(payload["repository_root"]) != nil else {
            throw invalid("repository_root must be a non-empty string")
        }
        if let ruleset = payload["ruleset_sha256"], !(ruleset is NSNull) {
            guard let ruleset = ruleset as? String, reviewIsLowerHex(ruleset, lengths: [64]) else {
                throw invalid("ruleset_sha256 must be null or 64 lowercase hex characters")
            }
        }

        guard let source = payload["source"] as? [String: Any] else {
            throw invalid("source must be an object")
        }
        try reviewValidateSource(source, label: "source", invalid: invalid)

        guard let brief = payload["brief"] as? [String: Any] else {
            throw invalid("brief must be an object")
        }
        try reviewValidateBrief(brief, invalid: invalid)

        guard let createdAt = reviewNonemptyString(payload["created_at"]),
              let createdAtDate = ISO8601DateFormatter().date(from: createdAt) else {
            throw invalid("created_at must be an ISO-8601 timestamp")
        }

        guard let summary = payload["summary"] as? [String: Any] else {
            throw invalid("summary must be an object")
        }
        let summaryKeys: Set<String> = [
            "hypotheses_investigated",
            "suppressed",
            "refuted",
            "verified",
            "human_judgment"
        ]
        guard Set(summary.keys) == summaryKeys else {
            throw invalid("summary has unexpected or missing fields")
        }
        for key in summaryKeys {
            guard let value = reviewNonnegativeInt(summary[key]) else {
                throw invalid("summary.\(key) must be a non-negative integer")
            }
            if value > 1_000_000 {
                throw invalid("summary.\(key) exceeds the admitted boundary")
            }
        }

        guard let findings = payload["findings"] as? [[String: Any]] else {
            throw invalid("findings must be an array")
        }
        guard findings.count <= 10_000 else {
            throw invalid("findings exceeds the admitted boundary")
        }

        var ids = Set<String>()
        for finding in findings {
            try reviewValidateFinding(
                finding,
                source: source,
                seenIDs: &ids,
                invalid: invalid
            )
        }

        let refuted = findings.filter { ($0["disposition"] as? String) == "refuted" }.count
        let suppressed = findings.filter { ($0["disposition"] as? String) == "suppressed" }.count
        let human = findings.filter { ($0["disposition"] as? String) == "human_required" }.count
        let verified = findings.filter { finding in
            guard let verification = finding["verification"] as? [String: Any],
                  let result = verification["result"] as? String else {
                return false
            }
            return result == "reproduced" || result == "supported_static"
        }.count

        guard reviewNonnegativeInt(summary["refuted"]) == refuted else {
            throw invalid("summary.refuted disagrees with retained findings")
        }
        guard reviewNonnegativeInt(summary["suppressed"]) == suppressed else {
            throw invalid("summary.suppressed disagrees with retained findings")
        }
        guard reviewNonnegativeInt(summary["human_judgment"]) == human else {
            throw invalid("summary.human_judgment disagrees with retained findings")
        }
        guard reviewNonnegativeInt(summary["verified"]) == verified else {
            throw invalid("summary.verified disagrees with retained findings")
        }
        guard let investigated = reviewNonnegativeInt(summary["hypotheses_investigated"]),
              investigated >= findings.count else {
            throw invalid("summary.hypotheses_investigated is smaller than retained findings")
        }

        return createdAtDate
    }

    private func reviewValidateBrief(
        _ brief: [String: Any],
        invalid: (String) -> CLIError
    ) throws {
        let keys: Set<String> = [
            "intent",
            "requirements",
            "out_of_scope_changes",
            "behavior_changed",
            "risk_areas",
            "file_groups",
            "reading_order",
            "safeguards",
            "coverage_gaps"
        ]
        guard Set(brief.keys) == keys,
              reviewNonemptyString(brief["intent"]) != nil,
              brief["out_of_scope_changes"] is [String],
              brief["behavior_changed"] is [String],
              brief["reading_order"] is [String],
              brief["safeguards"] is [String],
              brief["coverage_gaps"] is [String] else {
            throw invalid("brief has invalid or missing fields")
        }

        guard let requirements = brief["requirements"] as? [[String: Any]] else {
            throw invalid("brief.requirements must be an array")
        }
        let requirementKeys: Set<String> = ["requirement", "status", "evidence"]
        for requirement in requirements {
            guard Set(requirement.keys) == requirementKeys,
                  reviewNonemptyString(requirement["requirement"]) != nil,
                  let status = requirement["status"] as? String,
                  ["satisfied", "missing", "uncertain"].contains(status),
                  requirement["evidence"] is [String] else {
                throw invalid("brief.requirements contains an invalid requirement")
            }
        }

        guard let risks = brief["risk_areas"] as? [[String: Any]] else {
            throw invalid("brief.risk_areas must be an array")
        }
        for risk in risks {
            let allowed: Set<String> = ["level", "area", "reason"]
            guard Set(risk.keys).isSubset(of: allowed),
                  risk["level"] != nil,
                  risk["area"] != nil,
                  let level = risk["level"] as? String,
                  ["high", "medium", "low"].contains(level),
                  reviewNonemptyString(risk["area"]) != nil else {
                throw invalid("brief.risk_areas contains an invalid risk")
            }
            if let reason = risk["reason"], !(reason is NSNull),
               reviewNonemptyString(reason) == nil {
                throw invalid("brief.risk_areas reason must be a non-empty string when present")
            }
        }

        guard let groups = brief["file_groups"] as? [[String: Any]] else {
            throw invalid("brief.file_groups must be an array")
        }
        for group in groups {
            let keys: Set<String> = ["label", "paths"]
            guard Set(group.keys) == keys,
                  reviewNonemptyString(group["label"]) != nil,
                  group["paths"] is [String] else {
                throw invalid("brief.file_groups contains an invalid group")
            }
        }
    }

    private func reviewValidateFinding(
        _ finding: [String: Any],
        source: [String: Any],
        seenIDs: inout Set<String>,
        invalid: (String) -> CLIError
    ) throws {
        let allowed: Set<String> = [
            "id",
            "title",
            "severity",
            "claims",
            "failure_mode",
            "paths",
            "discovery_sources",
            "challenge",
            "verification",
            "repair",
            "disposition"
        ]
        let required: Set<String> = allowed.subtracting(["repair"])
        guard Set(finding.keys).isSubset(of: allowed),
              required.isSubset(of: Set(finding.keys)),
              let id = reviewNonemptyString(finding["id"]),
              seenIDs.insert(id).inserted,
              reviewNonemptyString(finding["title"]) != nil,
              reviewNonemptyString(finding["failure_mode"]) != nil,
              let severity = finding["severity"] as? String,
              ["P0", "P1", "P2", "P3"].contains(severity),
              finding["paths"] is [String],
              finding["discovery_sources"] is [String] else {
            throw invalid("findings contains an invalid finding")
        }

        guard let claims = finding["claims"] as? [[String: Any]], !claims.isEmpty else {
            throw invalid("finding \(id) must retain at least one claim")
        }
        var hasStrongClaim = false
        var hasUnknownClaim = false
        for claim in claims {
            let keys: Set<String> = ["kind", "message", "evidence"]
            guard Set(claim.keys) == keys,
                  let kind = claim["kind"] as? String,
                  ["proven", "derived", "observed", "inferred", "unknown"].contains(kind),
                  reviewNonemptyString(claim["message"]) != nil,
                  let evidence = claim["evidence"] as? [[String: Any]] else {
                throw invalid("finding \(id) contains an invalid claim")
            }
            hasStrongClaim = hasStrongClaim || kind == "proven" || kind == "derived"
            hasUnknownClaim = hasUnknownClaim || kind == "unknown"
            try reviewValidateEvidence(evidence, findingID: id, invalid: invalid)
        }

        guard let challenge = finding["challenge"] as? [String: Any],
              Set(challenge.keys) == Set(["disposition", "evidence"]),
              let challengeDisposition = challenge["disposition"] as? String,
              ["refuted", "survives_challenge", "uncertain"].contains(challengeDisposition),
              let challengeEvidence = challenge["evidence"] as? [[String: Any]] else {
            throw invalid("finding \(id) has an invalid challenge")
        }
        try reviewValidateEvidence(challengeEvidence, findingID: id, invalid: invalid)

        guard let verification = finding["verification"] as? [String: Any],
              Set(verification.keys) == Set(["result", "evidence"]),
              let verificationResult = verification["result"] as? String,
              ["reproduced", "supported_static", "not_reproduced", "blocked", "human_judgment"].contains(verificationResult),
              let verificationEvidence = verification["evidence"] as? [[String: Any]] else {
            throw invalid("finding \(id) has invalid verification")
        }
        try reviewValidateEvidence(verificationEvidence, findingID: id, invalid: invalid)

        guard let disposition = finding["disposition"] as? String,
              ["repaired", "refuted", "accepted_risk", "superseded", "human_required", "unresolved", "suppressed"].contains(disposition) else {
            throw invalid("finding \(id) has an invalid disposition")
        }

        if disposition == "refuted" && challengeDisposition != "refuted" {
            throw invalid("finding \(id) is refuted without challenger refutation")
        }
        if challengeDisposition == "refuted"
            && disposition != "refuted"
            && disposition != "suppressed" {
            throw invalid("finding \(id) survives after challenger refutation")
        }
        if (verificationResult == "reproduced" || verificationResult == "supported_static")
            && !hasStrongClaim {
            throw invalid("finding \(id) has supported verification without a proven or derived claim")
        }
        if disposition == "human_required"
            && !hasUnknownClaim
            && challengeDisposition != "uncertain"
            && verificationResult != "blocked"
            && verificationResult != "human_judgment" {
            throw invalid("finding \(id) requires a human without retained uncertainty")
        }

        if let repairValue = finding["repair"], !(repairValue is NSNull) {
            guard let repair = repairValue as? [String: Any] else {
                throw invalid("finding \(id) repair must be an object or null")
            }
            try reviewValidateRepair(
                repair,
                findingID: id,
                source: source,
                preRepairVerification: verificationResult,
                finalDisposition: disposition,
                invalid: invalid
            )
        } else if disposition == "repaired" {
            throw invalid("finding \(id) is repaired without a repair receipt")
        }
    }

    private func reviewValidateRepair(
        _ repair: [String: Any],
        findingID: String,
        source: [String: Any],
        preRepairVerification: String,
        finalDisposition: String,
        invalid: (String) -> CLIError
    ) throws {
        let allowed: Set<String> = ["attempted", "result", "after_source", "verification", "notes"]
        guard Set(repair.keys).isSubset(of: allowed),
              repair["attempted"] is Bool,
              let result = repair["result"] as? String,
              ["fixed", "failed", "deferred", "not_attempted"].contains(result) else {
            throw invalid("finding \(findingID) has an invalid repair receipt")
        }
        if let notes = repair["notes"], !(notes is NSNull),
           reviewNonemptyString(notes) == nil {
            throw invalid("finding \(findingID) repair notes must be a non-empty string when present")
        }

        guard finalDisposition == "repaired" else {
            return
        }
        guard repair["attempted"] as? Bool == true, result == "fixed" else {
            throw invalid("finding \(findingID) is repaired without an attempted fixed repair")
        }
        guard let afterSource = repair["after_source"] as? [String: Any] else {
            throw invalid("finding \(findingID) is repaired without after_source")
        }
        try reviewValidateSource(afterSource, label: "finding \(findingID) repair.after_source", invalid: invalid)
        guard !reviewSourcesEqual(source, afterSource) else {
            throw invalid("finding \(findingID) repaired source is unchanged")
        }
        guard let replay = repair["verification"] as? [String: Any],
              Set(replay.keys) == Set(["result", "evidence"]),
              replay["result"] as? String == "passed",
              let evidence = replay["evidence"] as? [[String: Any]],
              !evidence.isEmpty else {
            throw invalid("finding \(findingID) is repaired without passed evidence-bearing verification")
        }
        try reviewValidateEvidence(evidence, findingID: findingID, invalid: invalid)
        guard preRepairVerification == "reproduced" || preRepairVerification == "supported_static" else {
            throw invalid("finding \(findingID) is repaired without pre-repair evidence support")
        }
    }

    private func reviewValidateEvidence(
        _ evidence: [[String: Any]],
        findingID: String,
        invalid: (String) -> CLIError
    ) throws {
        let allowed: Set<String> = ["kind", "summary", "command", "path", "line"]
        let kinds = [
            "code_path",
            "guard",
            "test",
            "build",
            "static_analysis",
            "reproduction",
            "runtime_trace",
            "ui_automation",
            "counterexample",
            "human"
        ]
        for item in evidence {
            guard Set(item.keys).isSubset(of: allowed),
                  item["kind"] != nil,
                  item["summary"] != nil,
                  let kind = item["kind"] as? String,
                  kinds.contains(kind),
                  reviewNonemptyString(item["summary"]) != nil else {
                throw invalid("finding \(findingID) contains invalid evidence")
            }
            for key in ["command", "path"] {
                if let value = item[key], !(value is NSNull),
                   reviewNonemptyString(value) == nil {
                    throw invalid("finding \(findingID) evidence.\(key) must be a non-empty string")
                }
            }
            if let line = item["line"], !(line is NSNull),
               reviewNonnegativeInt(line).map({ $0 >= 1 }) != true {
                throw invalid("finding \(findingID) evidence.line must be a positive integer")
            }
        }
    }

    private func reviewValidateSource(
        _ source: [String: Any],
        label: String,
        invalid: (String) -> CLIError
    ) throws {
        let keys: Set<String> = [
            "repository_id",
            "base_sha",
            "head_sha",
            "tree_sha",
            "working_tree_dirty",
            "patch_sha256"
        ]
        guard Set(source.keys) == keys,
              reviewNonemptyString(source["repository_id"]) != nil,
              let base = source["base_sha"] as? String,
              let head = source["head_sha"] as? String,
              let tree = source["tree_sha"] as? String,
              reviewIsLowerHex(base, lengths: [40, 64]),
              reviewIsLowerHex(head, lengths: [40, 64]),
              reviewIsLowerHex(tree, lengths: [40, 64]),
              source["working_tree_dirty"] is Bool else {
            throw invalid("\(label) has invalid source identity")
        }
        if let patch = source["patch_sha256"], !(patch is NSNull) {
            guard let patch = patch as? String, reviewIsLowerHex(patch, lengths: [64]) else {
                throw invalid("\(label).patch_sha256 must be null or 64 lowercase hex characters")
            }
        }
    }

    private func reviewSourcesEqual(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        (lhs["repository_id"] as? String) == (rhs["repository_id"] as? String)
            && (lhs["base_sha"] as? String) == (rhs["base_sha"] as? String)
            && (lhs["tree_sha"] as? String) == (rhs["tree_sha"] as? String)
    }

    private func reviewNonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              !value.contains("\0") else {
            return nil
        }
        return value
    }

    private func reviewNonnegativeInt(_ value: Any?) -> Int? {
        guard let value = value as? Int, value >= 0 else {
            return nil
        }
        return value
    }

    private func reviewIsLowerHex(_ value: String, lengths: Set<Int>) -> Bool {
        guard lengths.contains(value.utf8.count) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
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

            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.review.error.invalidReceipt",
                        defaultValue: "Invalid cmux review receipt: %@"
                    ),
                    file.lastPathComponent
                ))
            }
            let createdAtDate = try reviewValidateReceiptPayload(
                payload,
                fileName: file.lastPathComponent
            )

            receipts.append(ReviewReceipt(
                id: file.deletingPathExtension().lastPathComponent,
                payload: payload,
                createdAtDate: createdAtDate
            ))
        }

        receipts.sort {
            if $0.createdAtDate == $1.createdAtDate {
                return $0.id > $1.id
            }
            return $0.createdAtDate > $1.createdAtDate
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
            arguments: ReviewCandidate.gitEnvironmentArguments() + ["git", "-C", directory, "rev-parse", "--show-toplevel"],
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
