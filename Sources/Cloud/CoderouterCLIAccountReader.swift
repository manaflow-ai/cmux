import Foundation

/// Reads the same CodeRouter Cloud account view shown by `cmux cr accounts`.
/// CodeRouter organizations have their own IDs, so the cmux team UUID is never
/// passed to CodeRouter directly.
enum CoderouterCLIAccountReader {
    static func accounts(for cmuxTeamName: String?) async throws -> [CloudTreeNode.CoderouterAccount] {
        if let cmuxTeamName,
           let organizationID = try await matchingOrganizationID(for: cmuxTeamName),
           try await currentOrganizationID() != organizationID {
            _ = try await run(["org", "switch", organizationID])
        }
        let output = try await run(["accounts", "--json"])
        let object = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let accounts = object?["accounts"] as? [[String: Any]] ?? []
        return accounts.compactMap { account in
            guard let id = account["id"] as? String,
                  let provider = (account["provider"] as? String) ?? (account["kind"] as? String) else {
                return nil
            }
            return CloudTreeNode.CoderouterAccount(
                id: id,
                provider: provider,
                label: account["label"] as? String,
                state: account["state"] as? String
            )
        }
    }

    private static func matchingOrganizationID(for cmuxTeamName: String) async throws -> String? {
        let output = try await run(["org", "list"])
        let wanted = normalized(cmuxTeamName)
        for rawLine in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let candidateID = tokens.last,
                  UUID(uuidString: String(candidateID)) != nil else { continue }
            let candidateName = tokens.dropLast().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if normalized(candidateName) == wanted {
                return String(candidateID)
            }
        }
        return nil
    }

    private static func currentOrganizationID() async throws -> String? {
        let output = try await run(["org", "current"])
        guard let token = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ")" })
            .last,
              UUID(uuidString: String(token)) != nil else { return nil }
        return String(token)
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

    private static func run(_ arguments: [String]) async throws -> Data {
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
