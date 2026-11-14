import Foundation

struct GitGraphSnapshotParser: Sendable {
    private static let fieldSeparator = Character("\0")
    private static let fieldsPerCommit = 6

    func commits(from output: Data) -> [GitGraphCommit] {
        guard let string = String(data: output, encoding: .utf8) else { return [] }
        let fields = string.split(separator: Self.fieldSeparator, omittingEmptySubsequences: false)
        guard fields.count >= Self.fieldsPerCommit else { return [] }

        var commits: [GitGraphCommit] = []
        let dateFormatter = ISO8601DateFormatter()
        var index = 0
        while index + Self.fieldsPerCommit <= fields.count {
            let oid = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oid.isEmpty else {
                index += 1
                continue
            }
            let parents = fields[index + 1].split(separator: " ").map(String.init)
            let references = parseReferences(String(fields[index + 2]))
            let author = String(fields[index + 3])
            let dateString = String(fields[index + 4])
            let subject = String(fields[index + 5])
            guard let authoredAt = dateFormatter.date(from: dateString) else {
                index += Self.fieldsPerCommit
                continue
            }
            commits.append(GitGraphCommit(
                oid: oid,
                parentOIDs: parents,
                references: references,
                author: author,
                authoredAt: authoredAt,
                subject: subject
            ))
            index += Self.fieldsPerCommit
        }
        return commits
    }

    private func parseReferences(_ decoration: String) -> [GitGraphReference] {
        decoration.split(separator: ",").compactMap { rawReference in
            let raw = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if raw == "HEAD" {
                return GitGraphReference(name: "HEAD", kind: .head)
            }
            if raw.hasPrefix("HEAD -> ") {
                let target = String(raw.dropFirst("HEAD -> ".count))
                return normalizedReference(target)
            }
            if raw.hasPrefix("tag: ") {
                let name = String(raw.dropFirst("tag: ".count))
                    .replacingOccurrences(of: "refs/tags/", with: "")
                return GitGraphReference(name: name, kind: .tag)
            }
            return normalizedReference(raw)
        }
    }

    private func normalizedReference(_ raw: String) -> GitGraphReference {
        if raw.hasPrefix("refs/heads/") {
            return GitGraphReference(
                name: String(raw.dropFirst("refs/heads/".count)),
                kind: .branch
            )
        }
        if raw.hasPrefix("refs/remotes/") {
            return GitGraphReference(
                name: String(raw.dropFirst("refs/remotes/".count)),
                kind: .remote
            )
        }
        if raw.hasPrefix("refs/tags/") {
            return GitGraphReference(
                name: String(raw.dropFirst("refs/tags/".count)),
                kind: .tag
            )
        }
        return GitGraphReference(name: raw, kind: .other)
    }
}

struct GitGraphLayout: Sendable {
    func rows(for commits: [GitGraphCommit]) -> [GitGraphRow] {
        var lanes: [GitGraphLane] = []
        var nextColorIndex = 0
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let nodeLane: Int
            if let existing = lanes.firstIndex(where: { $0.oid == commit.oid }) {
                nodeLane = existing
            } else {
                nodeLane = lanes.count
                lanes.append(GitGraphLane(oid: commit.oid, colorIndex: nextColorIndex))
                nextColorIndex += 1
            }

            let incoming = lanes
            let nodeColorIndex = incoming[nodeLane].colorIndex
            var outgoing = incoming
            if let firstParent = commit.parentOIDs.first {
                outgoing[nodeLane] = GitGraphLane(oid: firstParent, colorIndex: nodeColorIndex)
                for parent in commit.parentOIDs.dropFirst().reversed() where !outgoing.contains(where: { $0.oid == parent }) {
                    outgoing.insert(
                        GitGraphLane(oid: parent, colorIndex: nextColorIndex),
                        at: min(nodeLane + 1, outgoing.count)
                    )
                    nextColorIndex += 1
                }
            } else {
                outgoing.remove(at: nodeLane)
            }

            var seenOIDs: Set<String> = []
            outgoing.removeAll { !seenOIDs.insert($0.oid).inserted }
            rows.append(GitGraphRow(
                commit: commit,
                nodeLane: nodeLane,
                nodeColorIndex: nodeColorIndex,
                incomingLanes: incoming,
                outgoingLanes: outgoing
            ))
            lanes = outgoing
        }
        return rows
    }
}
