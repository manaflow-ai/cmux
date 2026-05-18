import Foundation

extension CMUXCLI {
    func renderMemorySamples(_ samples: [MemoryWorkspaceSample], idFormat: CLIIDFormat) -> String {
        guard !samples.isEmpty else { return "No workspace memory samples" }
        var lines = ["APPROX RSS  MEM%    CPU%    PROC  WORKSPACE       TITLE  TOP PROCESSES"]
        for sample in samples {
            let handle = memoryWorkspaceHandle(
                id: sample.workspaceId,
                ref: sample.workspaceRef,
                idFormat: idFormat
            )
            let rss = padLeft(formatBytes(sample.residentBytes), width: 10)
            let mem = padLeft(String(format: "%.1f%%", sample.memoryPercent), width: 7)
            let cpu = padLeft(String(format: "%.1f%%", sample.cpuPercent), width: 7)
            let proc = padLeft(String(sample.processCount), width: 5)
            let title = sample.workspaceTitle.isEmpty ? "-" : sample.workspaceTitle
            let processes = sample.topProcessNames.isEmpty ? "-" : sample.topProcessNames.joined(separator: ",")
            lines.append("\(rss)  \(mem)  \(cpu)  \(proc)  \(padRight(handle, width: 15)) \(title)  \(processes)")
        }
        return lines.joined(separator: "\n")
    }

    func renderMemoryTopRows(_ rows: [[String: Any]], idFormat: CLIIDFormat) -> String {
        guard !rows.isEmpty else { return "No memory samples in selected time window" }
        var lines = ["PEAK RSS    AVG RSS     PEAK MEM  AVG MEM   PEAK CPU  AVG CPU   SAMPLES  LAST SAMPLE           WORKSPACE       TITLE"]
        for row in rows {
            let handle = memoryWorkspaceHandle(
                id: row["workspace_id"] as? String,
                ref: row["workspace_ref"] as? String,
                idFormat: idFormat
            )
            let peakRSS = padLeft(formatBytes(topInt64(row["peak_rss_bytes"])), width: 10)
            let avgRSS = padLeft(formatBytes(topAverageByteCount(row["avg_rss_bytes"])), width: 10)
            let peakMem = padLeft(String(format: "%.1f%%", topDouble(row["peak_memory_percent"])), width: 8)
            let avgMem = padLeft(String(format: "%.1f%%", topDouble(row["avg_memory_percent"])), width: 8)
            let peakCPU = padLeft(String(format: "%.1f%%", topDouble(row["peak_cpu_percent"])), width: 8)
            let avgCPU = padLeft(String(format: "%.1f%%", topDouble(row["avg_cpu_percent"])), width: 8)
            let samples = padLeft(String(topInt(row["sample_count"]) ?? 0), width: 7)
            let lastSample = (row["last_sampled_at"] as? String) ?? "-"
            let title = topLabelText(row["workspace_title"] as? String)
            lines.append("\(peakRSS)  \(avgRSS)  \(peakMem)  \(avgMem)  \(peakCPU)  \(avgCPU)  \(samples)  \(lastSample.padding(toLength: 21, withPad: " ", startingAt: 0)) \(padRight(handle, width: 15)) \(title.isEmpty ? "-" : title)")
        }
        return lines.joined(separator: "\n")
    }

    private func topAverageByteCount(_ raw: Any?) -> Int64 {
        let value = topDouble(raw)
        guard value.isFinite, value >= 0, value < Double(Int64.max) else {
            return 0
        }
        return Int64(value.rounded(.towardZero))
    }

    func renderMemoryTrimResult(_ result: MemoryTrimResult, idFormat: CLIIDFormat) -> String {
        let workspace = memoryWorkspaceHandle(
            id: result.workspaceId,
            ref: result.workspaceRef,
            idFormat: idFormat
        )
        let mode = result.dryRun ? "Would trim" : "Trimmed"
        var parts = [
            "\(mode) \(result.agent.displayName)",
            "pid=\(result.agent.pid)",
            "workspace=\(workspace)",
            "rss=\(formatBytes(result.agent.residentBytes))"
        ]
        if let gracefulAction = result.gracefulAction {
            parts.append("graceful=\"\(gracefulAction)\"")
        }
        parts.append("terminated=\(result.terminated ? "yes" : "no")")
        parts.append("killed=\(result.killed ? "yes" : "no")")
        parts.append("still_running=\(result.stillRunning ? "yes" : "no")")
        return parts.joined(separator: " ")
    }

    func memoryWorkspaceHandle(id: String?, ref: String?, idFormat: CLIIDFormat) -> String {
        switch idFormat {
        case .refs:
            return (ref?.isEmpty == false ? ref : nil) ?? id ?? "?"
        case .uuids:
            return (id?.isEmpty == false ? id : nil) ?? ref ?? "?"
        case .both:
            let joined = [ref, id].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " ")
            return joined.isEmpty ? "?" : joined
        }
    }
}
