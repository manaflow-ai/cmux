import Foundation
import OSLog

/// Reads the same CodeRouter Cloud account view shown by `cmux cr accounts`.
/// CodeRouter organizations have their own IDs, so the cmux team UUID is never
/// passed to CodeRouter directly.
enum CoderouterCLIAccountReader {
    typealias Run = @Sendable (_ arguments: [String]) async throws -> Data

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")

    static func accounts(
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run = runCLI
    ) async throws -> [CloudTreeNode.CoderouterAccount] {
        guard let cmuxTeamName = cmuxTeamName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmuxTeamName.isEmpty,
              let organizationID = try await matchingOrganizationID(for: cmuxTeamID, name: cmuxTeamName, run: run) else {
            logger.error("No CodeRouter organization matched cmux team ID \(cmuxTeamID ?? "<nil>", privacy: .public), name \(String(describing: cmuxTeamName), privacy: .public)")
            throw accountError("The selected cmux team is not mapped to a CodeRouter organization.")
        }

        // `accounts` reads the CLI's active organization, which the user's terminal
        // shares. Its payload names that organization as `teamId`, so trust only the
        // payload and switch only when the selected team's organization is not active.
        var payload = try await readAccounts(run: run)
        if payload.organizationID != organizationID {
            _ = try await run(["org", "switch", organizationID])
            payload = try await readAccounts(run: run)
        }
        guard payload.organizationID == organizationID else {
            logger.error("CodeRouter accounts were for org ID \(payload.organizationID ?? "<nil>", privacy: .public), expected \(organizationID, privacy: .public)")
            throw accountError("CodeRouter organization did not switch to the selected team.")
        }
        logger.info("Loaded \(payload.accounts.count, privacy: .public) CodeRouter accounts for org ID \(organizationID, privacy: .public)")
        return payload.accounts
    }

    /// Removes one account from the CodeRouter organization of the selected cmux
    /// team, selecting that organization first exactly as `accounts` reads it.
    static func remove(
        accountID: String,
        for cmuxTeamID: String?,
        name cmuxTeamName: String?,
        run: Run = runCLI
    ) async throws {
        guard UUID(uuidString: accountID) != nil else {
            throw accountError("That CodeRouter account ID is not valid.")
        }
        _ = try await accounts(for: cmuxTeamID, name: cmuxTeamName, run: run)
        _ = try await run(["remove", accountID, "--yes"])
        logger.info("Removed CodeRouter account \(accountID, privacy: .public)")
    }

    private static func readAccounts(run: Run) async throws -> (organizationID: String?, accounts: [CloudTreeNode.CoderouterAccount]) {
        let output = try await run(["accounts", "--json"])
        let object = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let accounts = object?["accounts"] as? [[String: Any]] ?? []
        let result: [CloudTreeNode.CoderouterAccount] = accounts.compactMap { account in
            guard let id = account["id"] as? String,
                  let provider = (account["provider"] as? String) ?? (account["kind"] as? String) else {
                return nil
            }
            return CloudTreeNode.CoderouterAccount(
                id: id,
                provider: CoderouterProvider(id: provider.lowercased()),
                label: account["label"] as? String,
                state: account["state"] as? String,
                remainingPercent: remainingPercent(usage: account["usage"])
            )
        }
        return (object?["teamId"] as? String, result)
    }

    /// The share of the account's current rate-limit window still unused, the
    /// "93% left" `cr accounts` prints. Nil when the provider reports no window.
    private static func remainingPercent(usage: Any?) -> Int? {
        guard let usage = usage as? [String: Any],
              let rateLimit = usage["rate_limit"] as? [String: Any],
              let window = rateLimit["primary_window"] as? [String: Any],
              let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        return min(100, max(0, Int((100 - used).rounded())))
    }

    private static func matchingOrganizationID(for cmuxTeamID: String?, name cmuxTeamName: String, run: Run) async throws -> String? {
        let output = try await run(["org", "list"])
        let wanted = normalized(cmuxTeamName)
        for rawLine in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let candidateID = tokens.last,
                  UUID(uuidString: String(candidateID)) != nil else { continue }
            if String(candidateID) == cmuxTeamID { return String(candidateID) }
            let candidateName = tokens.dropLast().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if normalized(candidateName) == wanted {
                return String(candidateID)
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        var result = value.lowercased()
            .replacingOccurrences(of: "’s team", with: "")
            .replacingOccurrences(of: "'s team", with: "")
            .replacingOccurrences(of: " team", with: "")
        result = result.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }.reduce(into: "") { $0.append($1) }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func accountError(_ message: String) -> NSError {
        NSError(domain: "CoderouterCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Sendable private static func runCLI(_ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["coderouter"] + arguments
        var environment = ProcessInfo.processInfo.environment
        let installBin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".coderouter/bin").path
        environment["PATH"] = installBin + ":" + (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("coderouter \(arguments.joined(separator: " "), privacy: .public) failed: \(message, privacy: .public)")
                    continuation.resume(throwing: NSError(domain: "CoderouterCLI", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]))
                    return
                }
                continuation.resume(returning: data)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
