import Foundation

private struct RovoDevMetadata: Decodable {
    let title: String?
    let workspacePath: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case workspacePath = "workspace_path"
        case workspacePathCamel = "workspacePath"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
            ?? container.decodeIfPresent(String.self, forKey: .workspacePathCamel)
    }
}

private struct RovoDevSessionCandidate: Sendable {
    let sessionId: String
    let metadataURL: URL
    let sessionContextURL: URL
    let mtime: Date
}

extension SessionIndexStore {
    /// Returns Rovo Dev session entries paginated by metadata.json mtime desc.
    /// Sessions live at `~/.rovodev/sessions/<id>/metadata.json`.
    nonisolated static func loadRovoDevEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        sessionsRoot: String = ("~/.rovodev/sessions" as NSString).expandingTildeInPath
    ) -> [SessionEntry] {
        guard limit > 0 else { return [] }

        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let sessionURLs: [URL]
        do {
            sessionURLs = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            errorBag.add("Rovo Dev: cannot read sessions directory \(rootURL.path) (\(error.localizedDescription))")
            return []
        }

        var candidates: [RovoDevSessionCandidate] = []
        candidates.reserveCapacity(sessionURLs.count)
        for sessionURL in sessionURLs {
            guard (try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let metadataURL = sessionURL.appendingPathComponent("metadata.json", isDirectory: false)
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }

            let metadataValues: URLResourceValues
            do {
                metadataValues = try metadataURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
            } catch {
                errorBag.add("Rovo Dev: cannot inspect \(metadataURL.path) (\(error.localizedDescription))")
                continue
            }
            guard metadataValues.isRegularFile == true,
                  let mtime = metadataValues.contentModificationDate else {
                continue
            }

            candidates.append(RovoDevSessionCandidate(
                sessionId: sessionURL.lastPathComponent,
                metadataURL: metadataURL,
                sessionContextURL: sessionURL.appendingPathComponent("session_context.json", isDirectory: false),
                mtime: mtime
            ))
        }
        candidates.sort { $0.mtime > $1.mtime }

        let target = offset + limit
        var matchedCount = 0
        var results: [SessionEntry] = []
        results.reserveCapacity(limit)
        let decoder = JSONDecoder()

        for candidate in candidates {
            if Task.isCancelled { break }
            if matchedCount >= target { break }

            let metadata: RovoDevMetadata
            do {
                let data = try Data(contentsOf: candidate.metadataURL)
                metadata = try decoder.decode(RovoDevMetadata.self, from: data)
            } catch {
                errorBag.add("Rovo Dev: cannot read metadata \(candidate.metadataURL.path) (\(error.localizedDescription))")
                continue
            }

            let title = metadata.title ?? ""
            let cwd = metadata.workspacePath
            if let cwdFilter, cwd != cwdFilter {
                continue
            }
            if !needle.isEmpty {
                let haystack = [candidate.sessionId, title, cwd ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                guard haystack.range(of: needle, options: [.literal]) != nil else {
                    continue
                }
            }

            if matchedCount >= offset {
                results.append(SessionEntry(
                    id: "rovodev:" + candidate.sessionId,
                    agent: .rovodev,
                    sessionId: candidate.sessionId,
                    title: title,
                    cwd: cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: candidate.mtime,
                    fileURL: regularFileURL(candidate.sessionContextURL),
                    specifics: .rovodev
                ))
            }
            matchedCount += 1
        }
        return results
    }

    nonisolated private static func regularFileURL(_ url: URL) -> URL? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return url
    }

    #if DEBUG
    nonisolated static func loadRovoDevEntriesForTesting(
        sessionsRoot: String,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) -> SearchOutcome {
        let bag = ErrorBag()
        let entries = loadRovoDevEntries(
            needle: needle.lowercased(),
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            sessionsRoot: sessionsRoot
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif
}
