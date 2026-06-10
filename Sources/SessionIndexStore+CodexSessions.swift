import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


// MARK: - Codex session scanning
extension SessionIndexStore {
    /// Returns a usable user-prompt string from a Codex `user_message` /
    /// `response_item.input_text` payload, or nil when the message is just an
    /// envelope/system wrapper (`<environment_context>...`, `<user_instructions>`,
    /// `<permissions>`, AGENTS.md preamble) that we don't want to surface as a
    /// session title.
    nonisolated static func realCodexUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let envelopePrefixes = [
            "<environment_context",
            "<user_instructions",
            "<permissions",
            "<system",
            "# AGENTS.md",
        ]
        for prefix in envelopePrefixes where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
    }

    private struct CodexParsed {
        var sessionId: String = ""
        /// First user message — used only if Codex never assigns a thread_name.
        var firstUserMessage: String = ""
        /// Codex-generated session title (`event_msg.thread_name_updated`). Wins over firstUserMessage.
        var threadName: String = ""
        var cwd: String?
        var branch: String?
        var model: String?
        var approvalPolicy: String?
        var sandboxMode: String?
        var effort: String?

        var title: String {
            threadName.isEmpty ? firstUserMessage : threadName
        }
    }

    /// Cheap cwd peek for Codex rollouts. `session_meta` is always the first line
    /// of the file, but the line itself can be 30+ KB (it embeds the full system
    /// prompt). Read up to 64 KB to cover that, parse the JSON, return cwd.
    nonisolated private static func peekCodexSessionMetaCwd(url: URL) -> String? {
        let head = readFileHead(url: url, byteCap: headByteCap)
        guard let nl = head.firstIndex(of: "\n") else { return nil }
        let firstLine = head[..<nl]
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return cwd
    }

    /// Stream lines from `url` until we have everything we need. The first user_message
    /// can sit ~100 KB into a Codex rollout (after huge base_instructions + AGENTS.md),
    /// so a fixed head buffer is unreliable.
    nonisolated private static func extractCodexMetadata(url: URL) -> CodexParsed {
        var out = CodexParsed()
        let maxBytes = 4 * 1024 * 1024
        forEachJSONLine(url: url, maxBytes: maxBytes) { obj in
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            if type == "session_meta", let p = payload {
                if let c = p["cwd"] as? String, !c.isEmpty { out.cwd = c }
                if let id = p["id"] as? String, !id.isEmpty { out.sessionId = id }
                if let git = p["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty {
                    out.branch = branch
                }
            }
            if type == "turn_context", let p = payload {
                if let m = p["model"] as? String, !m.isEmpty { out.model = m }
                if let a = p["approval_policy"] as? String, !a.isEmpty { out.approvalPolicy = a }
                if let sandbox = p["sandbox_policy"] as? [String: Any],
                   let s = sandbox["type"] as? String, !s.isEmpty {
                    out.sandboxMode = s
                }
                if let e = p["effort"] as? String, !e.isEmpty { out.effort = e }
            }
            if type == "event_msg", let p = payload,
               (p["type"] as? String) == "thread_name_updated",
               let name = p["thread_name"] as? String, !name.isEmpty {
                out.threadName = name
            }
            if out.firstUserMessage.isEmpty, type == "event_msg", let p = payload,
               (p["type"] as? String) == "user_message",
               let msg = p["message"] as? String,
               let real = realCodexUserMessage(msg) {
                out.firstUserMessage = real
            }
            if out.firstUserMessage.isEmpty, type == "response_item", let p = payload,
               (p["type"] as? String) == "message",
               (p["role"] as? String) == "user",
               let content = p["content"] as? [[String: Any]] {
                for part in content {
                    guard (part["type"] as? String) == "input_text",
                          let text = part["text"] as? String,
                          let real = realCodexUserMessage(text) else { continue }
                    out.firstUserMessage = real
                    break
                }
            }
            // Stop early once we have a real thread name + the launch metadata. If no
            // thread name appears we keep streaming until we at least have a user
            // message — Codex emits thread_name_updated late in newer versions but it's
            // still typically within the first few KB of events.
            return !out.threadName.isEmpty
                && out.cwd != nil
                && out.branch != nil
                && !out.sessionId.isEmpty
                && out.model != nil
        }
        return out
    }

    /// Returns Codex session entries paginated by mtime desc.
    /// Primary path: query Codex's own `~/.codex/state_5.sqlite` (`threads`
    /// table) — Codex pre-extracts cwd, title, model, branch, approval, sandbox,
    /// effort, and rollout_path so we don't need to read jsonl files at all.
    /// Fallback (DB missing): the file-scan path below.
    nonisolated static func loadCodexEntries(
        needle: String, cwdFilter: String?, offset: Int, limit: Int,
        errorBag: ErrorBag
    ) async -> [SessionEntry] {
        if let viaSQL = await loadCodexEntriesViaSQL(
            needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit,
            errorBag: errorBag
        ) {
            return viaSQL
        }
        return await loadCodexEntriesFromDisk(
            needle: needle, cwdFilter: cwdFilter, offset: offset, limit: limit
        )
    }

    /// Disk-scan fallback for Codex when state_5.sqlite isn't present (very old
    /// Codex installs, or non-default config). Same shape as the original loader.
    nonisolated private static func loadCodexEntriesFromDisk(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
    ) async -> [SessionEntry] {
        let root = ("~/.codex/sessions" as NSString).expandingTildeInPath
        let fm = FileManager.default

        var rgFiltered = false
        var candidates: [(URL, Date)] = []
        if !needle.isEmpty,
           let rgPaths = await ripgrepMatchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") {
            rgFiltered = true
            for url in rgPaths {
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                candidates.append((url, mtime))
            }
        } else {
            let rootURL = URL(fileURLWithPath: root)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true,
                      let mtime = values?.contentModificationDate else { continue }
                candidates.append((url, mtime))
            }
        }
        candidates.sort { $0.1 > $1.1 }

        let target = offset + limit
        var matches: [SessionEntry] = []
        var scanned = 0
        for (url, mtime) in candidates {
            if Task.isCancelled { break }
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1
            if !needle.isEmpty && !rgFiltered {
                let head = readFileHead(url: url, byteCap: headByteCap)
                guard head.range(of: needle, options: [.caseInsensitive, .literal]) != nil else { continue }
            }
            // Fast cwd reject: session_meta is the FIRST line of every Codex
            // rollout. Pull just that line and bail before streaming the
            // (potentially MB-sized) rest of the file looking for title/branch.
            if let cwdFilter,
               let firstLineCwd = peekCodexSessionMetaCwd(url: url),
               firstLineCwd != cwdFilter {
                continue
            }
            let parsed = extractCodexMetadata(url: url)
            if let cwdFilter, parsed.cwd != cwdFilter { continue }
            matches.append(SessionEntry(
                id: "codex:" + url.path,
                agent: .codex,
                sessionId: parsed.sessionId,
                title: parsed.title,
                cwd: parsed.cwd,
                gitBranch: parsed.branch,
                pullRequest: nil,
                modified: mtime,
                fileURL: url,
                specifics: .codex(
                    model: parsed.model,
                    approvalPolicy: parsed.approvalPolicy,
                    sandboxMode: parsed.sandboxMode,
                    effort: parsed.effort
                )
            ))
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

}
