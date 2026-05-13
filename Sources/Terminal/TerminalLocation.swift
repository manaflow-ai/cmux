import Darwin
import Foundation

nonisolated struct TerminalLocation: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case plainPath
        case osc7
    }

    enum GitBranchSignal: Equatable, Sendable {
        case unspecified
        case clear
        case branch(SidebarGitBranchState)
    }

    let host: String?
    let path: String
    let source: Source
    let gitBranchSignal: GitBranchSignal

    var isRemote: Bool {
        remoteHost != nil
    }

    var remoteHost: String? {
        guard let host = Self.normalizedHost(host), !Self.isLocalHost(host) else {
            return nil
        }
        return host
    }

    var gitBranch: SidebarGitBranchState? {
        guard case .branch(let branch) = gitBranchSignal else { return nil }
        return branch
    }

    var displayDirectory: String {
        guard let remoteHost else { return path }
        return "\(remoteHost):\(path)"
    }

    static func local(path: String, source: Source = .plainPath) -> TerminalLocation {
        TerminalLocation(host: nil, path: path, source: source, gitBranchSignal: .unspecified)
    }

    static func locationForDirectoryUpdate(_ directory: String) -> TerminalLocation? {
        let trimmedForEmptyCheck = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForEmptyCheck.isEmpty else { return nil }
        let newlineTrimmedDirectory = directory.trimmingCharacters(in: .newlines)
        return parseReportedDirectory(newlineTrimmedDirectory) ?? .local(path: newlineTrimmedDirectory)
    }

    static func parseOSC7Sequence(_ sequence: String) -> TerminalLocation? {
        let trimmed = sequence.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if trimmed.hasPrefix("\u{1B}]7;") {
            payload = String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("7;") {
            payload = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("file://") || trimmed.hasPrefix("kitty-shell-cwd://") {
            payload = trimmed
        } else {
            return nil
        }

        let terminated = payload.prefixBeforeFirstTerminalTerminator()
        return parseReportedDirectory(String(terminated), source: .osc7)
    }

    static func parseReportedDirectory(
        _ directory: String,
        source: Source = .plainPath
    ) -> TerminalLocation? {
        let trimmedForEmptyCheck = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForEmptyCheck.isEmpty else { return nil }

        let newlineTrimmed = directory.trimmingCharacters(in: .newlines)
        let uriCandidate = trimmedForEmptyCheck

        if uriCandidate.hasPrefix("\u{1B}]7;") {
            return parseOSC7Sequence(uriCandidate)
        }

        guard uriCandidate.hasPrefix("file://") || uriCandidate.hasPrefix("kitty-shell-cwd://") else {
            return local(path: newlineTrimmed, source: source)
        }

        guard let components = URLComponents(string: uriCandidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "file" || scheme == "kitty-shell-cwd" else {
            return local(path: newlineTrimmed, source: source)
        }

        let decodedPath = components.percentEncodedPath.removingPercentEncoding ?? components.path
        guard !decodedPath.isEmpty else { return nil }
        let path = normalizedReportedURIPath(decodedPath)

        let host = Self.normalizedHost(components.percentEncodedHost?.removingPercentEncoding ?? components.host)
        let remote = host.flatMap { Self.isLocalHost($0) ? nil : $0 }
        let branchSignal = gitBranchSignal(from: components.queryItems ?? [], isRemote: remote != nil)
        return TerminalLocation(
            host: remote,
            path: path,
            source: source,
            gitBranchSignal: branchSignal
        )
    }

    private static func gitBranchSignal(
        from queryItems: [URLQueryItem],
        isRemote: Bool
    ) -> GitBranchSignal {
        let branch = queryItems
            .first { $0.name == "cmux_git_branch" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let branch, !branch.isEmpty else {
            return isRemote ? .clear : .unspecified
        }
        let dirtyValue = queryItems
            .first { $0.name == "cmux_git_dirty" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isDirty = dirtyValue == "1" || dirtyValue == "true" || dirtyValue == "dirty"
        return .branch(SidebarGitBranchState(branch: branch, isDirty: isDirty))
    }

    private static func normalizedHost(_ host: String?) -> String? {
        var trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedReportedURIPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1, normalized.last == "/" {
            normalized.removeLast()
        }
        return normalized
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = normalizedHost(host)?.lowercased() ?? ""
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" || normalized == "::1" || isIPv4Loopback(normalized) {
            return true
        }

        return localHostnameCandidates.contains(normalized)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.first == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part),
                  value <= 255 else {
                return false
            }
            return true
        }
    }

    private static let localHostnameCandidates: Set<String> = {
        var names = [ProcessInfo.processInfo.hostName]
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.append(String(cString: buffer))
        }
        return Set(names.flatMap { name -> [String] in
            guard let lower = normalizedHost(name)?.lowercased() else { return [] }
            let short = lower.split(separator: ".").first.map(String.init)
            return [lower, short].compactMap { $0 }
        })
    }()
}

extension TerminalLocation {
    init?(sessionSnapshot snapshot: SessionTerminalLocationSnapshot) {
        guard !snapshot.path.isEmpty else { return nil }
        let restoredSource: Source = {
            switch snapshot.source {
            case .osc7:
                return .osc7
            case .plainPath, nil:
                return .plainPath
            }
        }()
        self.init(
            host: Self.normalizedHost(snapshot.host).flatMap { Self.isLocalHost($0) ? nil : $0 },
            path: snapshot.path,
            source: restoredSource,
            gitBranchSignal: .unspecified
        )
    }

    var sessionSnapshot: SessionTerminalLocationSnapshot {
        let snapshotSource: SessionTerminalLocationSource = {
            switch source {
            case .plainPath:
                return .plainPath
            case .osc7:
                return .osc7
            }
        }()
        return SessionTerminalLocationSnapshot(host: remoteHost, path: path, source: snapshotSource)
    }
}

private extension String {
    func prefixBeforeFirstTerminalTerminator() -> Substring {
        let stRange = range(of: "\u{1B}\\")
        let belRange = range(of: "\u{7}")
        let c1Range = range(of: "\u{9C}")
        let terminators = [stRange, belRange, c1Range].compactMap { $0?.lowerBound }
        guard let first = terminators.min() else { return self[...] }
        return self[..<first]
    }
}
