import Foundation

extension GrokSessionLocator {
    /// Finds the latest Grok session persisted for the observed process working directory.
    func latestSessionID(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        guard let workingDirectory = processWorkingDirectory(for: process) else {
            return nil
        }

        let homeDirectory = processHomeDirectory(for: process)
        let roots = Self.sessionRoots(
            registration: registration,
            cwdFilter: workingDirectory,
            environment: process.environment,
            homeDirectory: homeDirectory
        )
        let fractionalTimestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plainTimestampFormat = Date.ISO8601FormatStyle()
        let decoder = JSONDecoder()
        let candidates = roots.flatMap { root in
            sessionCandidates(
                in: root,
                decoder: decoder,
                fractionalTimestampFormat: fractionalTimestampFormat,
                plainTimestampFormat: plainTimestampFormat
            )
        }

        if let latest = latestCandidate(from: candidates, rankedBy: \.contentTimestamp) {
            return latest.sessionID
        }

        // Grok lock files and session directories can be touched independently of conversation
        // activity. Only when no summary has a content timestamp do we use summary.json itself.
        return latestCandidate(from: candidates, rankedBy: \.summaryModifiedAt)?.sessionID
    }

    private func processWorkingDirectory(for process: VaultObservedAgentProcess) -> String? {
        for rawValue in [
            process.environment["CMUX_AGENT_LAUNCH_CWD"],
            process.environment["PWD"],
        ] {
            guard let workingDirectory = Self.normalizedWorkingDirectory(rawValue),
                  (workingDirectory as NSString).isAbsolutePath else {
                continue
            }
            return workingDirectory
        }
        return nil
    }

    private func processHomeDirectory(for process: VaultObservedAgentProcess) -> String {
        guard let homeDirectory = Self.normalizedWorkingDirectory(process.environment["HOME"]),
              (homeDirectory as NSString).isAbsolutePath else {
            return NSHomeDirectory()
        }
        return homeDirectory
    }

    private func sessionCandidates(
        in root: GrokSessionRoot,
        decoder: JSONDecoder,
        fractionalTimestampFormat: Date.ISO8601FormatStyle,
        plainTimestampFormat: Date.ISO8601FormatStyle
    ) -> [ProcessDiscoveryCandidate] {
        let projectDirectory = URL(fileURLWithPath: root.sessionsRoot, isDirectory: true)
        let sessionDirectories: [URL]
        do {
            sessionDirectories = try fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var candidates: [ProcessDiscoveryCandidate] = []
        for sessionDirectory in sessionDirectories {
            do {
                let directoryValues = try sessionDirectory.resourceValues(forKeys: [.isDirectoryKey])
                guard directoryValues.isDirectory == true else { continue }

                let summaryURL = sessionDirectory.appendingPathComponent("summary.json", isDirectory: false)
                let summaryValues = try summaryURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
                guard summaryValues.isRegularFile == true else { continue }

                let contentTimestamp: Date?
                do {
                    let data = try Data(contentsOf: summaryURL)
                    let summary = try decoder.decode(ProcessDiscoverySummary.self, from: data)
                    contentTimestamp = summaryTimestamp(
                        summary,
                        fractionalTimestampFormat: fractionalTimestampFormat,
                        plainTimestampFormat: plainTimestampFormat
                    )
                } catch {
                    // A partially written summary must not abort scanning the other sessions.
                    contentTimestamp = nil
                }

                candidates.append(ProcessDiscoveryCandidate(
                    sessionID: sessionDirectory.lastPathComponent,
                    contentTimestamp: contentTimestamp,
                    summaryModifiedAt: summaryValues.contentModificationDate
                ))
            } catch {
                continue
            }
        }
        return candidates
    }

    private func summaryTimestamp(
        _ summary: ProcessDiscoverySummary,
        fractionalTimestampFormat: Date.ISO8601FormatStyle,
        plainTimestampFormat: Date.ISO8601FormatStyle
    ) -> Date? {
        for rawValue in [summary.lastActiveAt, summary.updatedAt, summary.createdAt] {
            guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty else {
                continue
            }
            do {
                return try fractionalTimestampFormat.parse(rawValue)
            } catch {
                do {
                    return try plainTimestampFormat.parse(rawValue)
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    private func latestCandidate(
        from candidates: [ProcessDiscoveryCandidate],
        rankedBy timestamp: (ProcessDiscoveryCandidate) -> Date?
    ) -> ProcessDiscoveryCandidate? {
        var latest: ProcessDiscoveryCandidate?
        var latestTimestamp: Date?
        for candidate in candidates {
            guard let candidateTimestamp = timestamp(candidate) else { continue }
            guard let current = latest, let currentTimestamp = latestTimestamp else {
                latest = candidate
                latestTimestamp = candidateTimestamp
                continue
            }
            if candidateTimestamp > currentTimestamp
                || (candidateTimestamp == currentTimestamp && candidate.sessionID > current.sessionID) {
                latest = candidate
                latestTimestamp = candidateTimestamp
            }
        }
        return latest
    }
}

private struct ProcessDiscoveryCandidate {
    let sessionID: String
    let contentTimestamp: Date?
    let summaryModifiedAt: Date?
}

private struct ProcessDiscoverySummary: Decodable {
    let createdAt: String?
    let updatedAt: String?
    let lastActiveAt: String?

    private enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastActiveAt = "last_active_at"
    }
}
