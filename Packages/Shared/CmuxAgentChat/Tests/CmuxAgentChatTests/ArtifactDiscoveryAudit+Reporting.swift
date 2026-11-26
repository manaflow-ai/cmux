import Foundation

extension ArtifactDiscoveryAudit {
    func printReport(_ measurements: [TranscriptMeasurement]) {
        for agent in ["claude", "codex"] {
            let subset = measurements.filter { $0.agent == agent }
            printAggregate(label: agent, measurements: subset)
        }
        printAggregate(label: "total", measurements: measurements)
        printExamples(phase: "before", measurements: measurements, usesAfter: false)
        printExamples(phase: "after", measurements: measurements, usesAfter: true)
        let beforeExtras = measurements.map(\.beforeExtraCount)
        let afterExtras = measurements.map(\.afterExtraCount)
        let growth = zip(beforeExtras, afterExtras).map { before, after in
            Double(after + 1) / Double(before + 1)
        }
        print(
            "ARTIFACT_PARITY_GROWTH "
                + "before_extra_median=\(percentile(beforeExtras, percentile: 0.50)) "
                + "before_extra_p95=\(percentile(beforeExtras, percentile: 0.95)) "
                + "after_extra_median=\(percentile(afterExtras, percentile: 0.50)) "
                + "after_extra_p95=\(percentile(afterExtras, percentile: 0.95)) "
                + "factor_median=\(String(format: "%.3f", percentile(growth, percentile: 0.50))) "
                + "factor_p95=\(String(format: "%.3f", percentile(growth, percentile: 0.95)))"
        )
    }

    private func printAggregate(label: String, measurements: [TranscriptMeasurement]) {
        let beforeTranscripts = measurements.filter { !$0.beforeViolations.isEmpty }.count
        let afterTranscripts = measurements.filter { !$0.afterViolations.isEmpty }.count
        let beforePairs = measurements.reduce(0) { $0 + $1.beforeViolations.count }
        let afterPairs = measurements.reduce(0) { $0 + $1.afterViolations.count }
        let excluded = measurements.reduce(0) { $0 + $1.excludedGalleryPaths.count }
        let nonAbsolute = measurements.reduce(0) { $0 + $1.nonAbsoluteGalleryPaths.count }
        print(
            "ARTIFACT_PARITY_AGGREGATE agent=\(label) transcripts=\(measurements.count) "
                + "before_violation_transcripts=\(beforeTranscripts) before_pairs=\(beforePairs) "
                + "after_violation_transcripts=\(afterTranscripts) after_pairs=\(afterPairs) "
                + "excluded_gallery=\(excluded) non_absolute_gallery=\(nonAbsolute)"
        )
    }

    private func printExamples(
        phase: String,
        measurements: [TranscriptMeasurement],
        usesAfter: Bool
    ) {
        var examples: [ViolationExample] = []
        for measurement in measurements {
            let violations = usesAfter ? measurement.afterViolations : measurement.beforeViolations
            let channels = usesAfter ? measurement.afterChannels : measurement.beforeChannels
            for path in violations {
                examples.append(
                    ViolationExample(
                        agent: measurement.agent,
                        transcriptPath: measurement.transcriptPath,
                        artifactPath: path,
                        channels: (channels[path] ?? []).sorted().joined(separator: ",")
                    )
                )
            }
        }
        examples.sort {
            ($0.agent, $0.transcriptPath, $0.artifactPath)
                < ($1.agent, $1.transcriptPath, $1.artifactPath)
        }
        for (index, example) in examples.prefix(10).enumerated() {
            print(
                "ARTIFACT_PARITY_EXAMPLE phase=\(phase) rank=\(index + 1) "
                    + "agent=\(example.agent) channel=\(example.channels) "
                    + "path=\(example.artifactPath) transcript=\(example.transcriptPath)"
            )
        }
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        return sorted[index]
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))
        return sorted[index]
    }

    func newestClaudeTranscripts(root: URL) -> [URL] {
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let files = projectDirectories.flatMap { directory -> [URL] in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { return [] }
            return children.filter { $0.pathExtension == "jsonl" }
        }
        return newest(files)
    }

    func newestCodexTranscripts(root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where
            url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            files.append(url)
        }
        return newest(files)
    }

    private func newest(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            return left > right
        }.prefix(limitPerAgent).map { $0 }
    }

    static func isCodexShellTool(_ name: String) -> Bool {
        ["shell", "exec_command", "local_shell_call", "container.exec"].contains(name)
    }

    static func isExcludedPath(_ path: String) -> Bool {
        !path.hasPrefix("/")
            || path.contains("://")
            || ["/dev", "/proc", "/sys"].contains { prefix in
                path == prefix || path.hasPrefix(prefix + "/")
            }
    }
}
