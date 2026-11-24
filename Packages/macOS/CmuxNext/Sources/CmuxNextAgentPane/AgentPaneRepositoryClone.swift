import CmuxNextCloud
import CmuxNextCompat
import Foundation

/// Local HTTPS clones initiated from the new-chat project picker.
@MainActor final class AgentPaneRepositoryClone {
    typealias Checkout = AgentPaneGitHubCheckout.Checkout

    nonisolated enum Failure: Error, Equatable, Sendable {
        case invalidURL, credentials, destinationTaken, cloneFailed, keyConflict

        @MainActor var reply: [String: Any] {
            switch self {
            case .invalidURL:
                AgentPaneReply.failure(code: "repo.invalid_url", message: AgentPaneModel.repositoryURLInvalidMessage)
            case .credentials:
                AgentPaneReply.failure(code: "repo.credentials", message: AgentPaneModel.repositoryURLCredentialsMessage)
            case .destinationTaken:
                AgentPaneReply.failure(code: "repo.destination_taken", message: AgentPaneModel.repositoryDestinationTakenMessage)
            case .cloneFailed:
                AgentPaneReply.failure(code: "repo.clone_failed", message: AgentPaneModel.repositoryCloneFailedMessage)
            case .keyConflict:
                AgentPaneReply.failure(code: "idempotency.conflict", message: AgentPaneModel.repositoryCloneFailedMessage)
            }
        }
    }

    private nonisolated struct Remote: Hashable, Sendable {
        let url: String
        let host: String
        let owner: String
        let name: String

        init(_ input: String) throws(Failure) {
            let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.utf8.count <= 4096, !raw.contains("\0"), !raw.contains("\\"),
                  let parsed = URLComponents(string: raw), parsed.scheme?.lowercased() == "https",
                  let host = parsed.host?.lowercased(), !host.isEmpty else { throw .invalidURL }
            guard parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil
            else { throw .credentials }
            guard parsed.port == nil else { throw .invalidURL }
            let repo: CloudMachineRepo
            do {
                repo = try CloudMachineRepo.parse(raw)
            } catch CloudMachineRepo.Invalid.credentialsInURL {
                throw .credentials
            } catch {
                throw .invalidURL
            }
            // The shared parser also accepts branch specs and web tree links. The local clone takes
            // an HTTPS remote URL with exactly the path components that will name its checkout.
            let expected = "/\(repo.owner)/\(repo.name)"
            let path = parsed.percentEncodedPath
            guard repo.ref == nil, host == repo.host || host == "www.github.com" && repo.isGitHub,
                  [expected, expected + ".git", expected + "/", expected + ".git/"].contains(path)
            else { throw .invalidURL }
            (self.url, self.host, self.owner, self.name) = (raw, repo.host, repo.owner, repo.name)
        }

        var destination: String { "\(host)/\(owner)/\(name)" }

        /// The same repository whatever form its URL takes (`.git`, a trailing slash, the host's case): the
        /// normalized host, owner and name; GitHub's owner and name ignore case as GitHub does.
        func matches(_ remote: Remote) -> Bool {
            if host == CloudMachineRepo.gitHub {
                return destination.caseInsensitiveCompare(remote.destination) == .orderedSame
            }
            return destination == remote.destination
        }

        /// Its folder under the clone root. A GitHub repository uses the GitHub picker's own layout
        /// (``AgentPaneGitHubCheckout``, `<owner>/<name>`), so a pasted github.com URL reuses that checkout.
        var parentPath: String { host == CloudMachineRepo.gitHub ? owner : "\(host)/\(owner)" }
    }

    private struct Running {
        let remote: Remote
        let task: Task<Result<Checkout, Failure>, Never>
    }

    private let root: URL
    private let git: AgentPaneGitHubCheckout.Git
    private var running: [String: Running] = [:]
    private var keys: [String: Remote] = [:]
    private var keyOrder: [String] = []

    init(root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appending(path: "cmux/repos", directoryHint: .isDirectory),
         git: @escaping AgentPaneGitHubCheckout.Git = AgentPaneGitHubCheckout.systemGit) {
        (self.root, self.git) = (root, git)
    }

    func checkout(url: String, key: String) async -> Result<Checkout, Failure> {
        let remote: Remote
        do {
            remote = try Remote(url)
        } catch {
            return .failure(error)
        }
        if let before = keys[key], before != remote { return .failure(.keyConflict) }
        if keys[key] == nil {
            keys[key] = remote
            keyOrder.append(key)
            if keyOrder.count > 128 { keys.removeValue(forKey: keyOrder.removeFirst()) }
        }
        let destinationKey = remote.destination.lowercased()
        if let request = running[destinationKey] {
            guard remote.matches(request.remote) else { return .failure(.destinationTaken) }
            return await request.task.value
        }
        let task = Task { await self.resolve(remote) }
        running[destinationKey] = Running(remote: remote, task: task)
        defer { running[destinationKey] = nil }
        return await task.value
    }

    private func resolve(_ remote: Remote) async -> Result<Checkout, Failure> {
        guard let parent = await Self.containedParent(of: remote.parentPath, under: root) else {
            return .failure(.destinationTaken)
        }
        let destination = parent.appending(path: remote.name, directoryHint: .isDirectory).path
        if await Self.matchesCheckout(destination, remote: remote, git: git) {
            return .success(.init(path: destination, cloned: false))
        }
        guard await AgentPaneGitHubCheckout.firstFree([destination]) != nil else { return .failure(.destinationTaken) }
        let git = self.git
        let result = await AgentPaneGitHubCheckout.installClone(in: parent, name: remote.name, destination: destination) { partial in
            // An HTTPS URL rewritten by local Git settings must still use HTTPS.
            let arguments = ["clone", "--quiet", "--", remote.url, partial]
            return await git(arguments, nil, ["GIT_ALLOW_PROTOCOL": "https"], AgentPaneGitHubCheckout.cloneTimeout)?.status == 0
        }
        switch result {
        case .success(let checkout): return .success(checkout)
        case .failure(.cloneFailed): return .failure(.cloneFailed)
        case .failure(.noFolder):
            if await Self.matchesCheckout(destination, remote: remote, git: git) {
                return .success(.init(path: destination, cloned: false))
            }
            return .failure(.destinationTaken)
        }
    }

    @concurrent private nonisolated static func containedParent(of relative: String, under root: URL) async -> URL? {
        let root = root.resolvingSymlinksInPath()
        var parent = root
        for component in relative.split(separator: "/") {
            parent = parent.appending(path: String(component), directoryHint: .isDirectory)
            if (try? FileManager.checked.destinationOfSymbolicLink(atPath: parent.path)) != nil { return nil }
        }
        return parent
    }

    @concurrent private nonisolated static func matchesCheckout(
        _ folder: String, remote: Remote, git: AgentPaneGitHubCheckout.Git
    ) async -> Bool {
        guard (try? FileManager.checked.destinationOfSymbolicLink(atPath: folder)) == nil,
              await AgentPaneGitHubCheckout.isFolder(folder) else { return false }
        let timeout = AgentPaneGitHubCheckout.readTimeout
        guard let top = await git(["rev-parse", "--show-toplevel"], folder, [:], timeout), top.status == 0,
              top.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == folder,
              let origin = await git(["config", "--local", "--get", "remote.origin.url"], folder, [:], timeout),
              origin.status == 0, let existing = try? Remote(Self.httpsForm(of: origin.stdout)) else { return false }
        return remote.matches(existing)
    }

    /// An existing checkout's origin in its HTTPS form, so a repository checked out over SSH
    /// (`git@github.com:acme/api.git`, `ssh://git@github.com/acme/api`) is the one an HTTPS URL names. Only for
    /// reading checkouts already there: a new clone still takes an HTTPS URL alone.
    nonisolated static func httpsForm(of origin: String) -> String {
        let raw = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("ssh://") {
            guard let parsed = URLComponents(string: raw), let host = parsed.host, !host.isEmpty else { return raw }
            return "https://\(host)\(parsed.percentEncodedPath)"
        }
        // scp-like `user@host:path` (no scheme, a colon before any slash).
        guard !raw.contains("://"), let at = raw.firstIndex(of: "@"), let colon = raw[at...].firstIndex(of: ":"),
              !raw[at..<colon].contains("/") else { return raw }
        let host = raw[raw.index(after: at)..<colon]
        let path = raw[raw.index(after: colon)...]
        guard !host.isEmpty, !path.isEmpty, !path.hasPrefix("/") else { return raw }
        return "https://\(host)/\(path)"
    }

    static func reply(url: String, key: String, userGesture: Bool, in model: AgentPaneModel) async -> [String: Any] {
        guard !model.remoteChat, model.gitWritesHere?() == true else { return AgentPaneModel.unsupported("repo.clone") }
        guard model.sessionId == nil else {
            return AgentPaneModel.gitFailure(.sessionChanged, message: AgentPaneModel.repositoryCloneFailedMessage)
        }
        guard userGesture || model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let pick = model.beginPick()
        let result = await model.repositoryClone.checkout(url: url, key: key)
        guard pick == model.pickSequence, model.sessionId == nil, !model.remoteChat else {
            return AgentPaneModel.gitFailure(.sessionChanged, message: AgentPaneModel.repositoryCloneFailedMessage)
        }
        switch result {
        case .success(let checkout):
            // The clone gesture authorizes this exact checkout. The next Send can start there.
            model.transport.grant(checkout.path)
            return AgentPaneReply.success(["cwd": checkout.path, "cloned": checkout.cloned])
        case .failure(let failure):
            return failure.reply
        }
    }
}
