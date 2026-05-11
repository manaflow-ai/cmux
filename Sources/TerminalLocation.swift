import Darwin
import Foundation

struct TerminalLocation: Equatable {
    enum Source: String, Equatable {
        case plainPath
        case osc7
    }

    enum GitBranchSignal: Equatable {
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

        if uriCandidate.hasPrefix("\u{1B}]7;") || uriCandidate.hasPrefix("7;") {
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

        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        guard !path.isEmpty else { return nil }

        let host = Self.normalizedHost(components.percentEncodedHost?.removingPercentEncoding ?? components.host)
        let remote = host.flatMap { Self.isLocalHost($0) ? nil : $0 }
        let branchSignal = gitBranchSignal(from: components.queryItems ?? [], isRemote: remote != nil)
        return TerminalLocation(
            host: host,
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
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" || normalized == "::1" || isIPv4Loopback(normalized) {
            return true
        }

        let candidates = Set(localHostnames().flatMap { name -> [String] in
            let lower = name.lowercased()
            let short = lower.split(separator: ".").first.map(String.init)
            return [lower, short].compactMap { $0 }
        })
        return candidates.contains(normalized)
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

    private static func localHostnames() -> [String] {
        var names = [ProcessInfo.processInfo.hostName]
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.append(String(cString: buffer))
        }
        return names
    }
}

extension TerminalLocation {
    init?(sessionSnapshot snapshot: SessionTerminalLocationSnapshot) {
        guard !snapshot.path.isEmpty else { return nil }
        self.init(
            host: snapshot.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            path: snapshot.path,
            source: Source(rawValue: snapshot.source ?? "") ?? .plainPath,
            gitBranchSignal: .unspecified
        )
    }

    var sessionSnapshot: SessionTerminalLocationSnapshot {
        SessionTerminalLocationSnapshot(host: remoteHost, path: path, source: source.rawValue)
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
