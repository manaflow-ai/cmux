internal import CmuxCore
import Foundation

/// Parsed TTY-scoped and host-wide evidence from one shared remote scan.
struct RemoteTTYPortScanOutput: Sendable, Equatable {
    let portsByTTY: [String: [Int]]
    let completeTTYNames: Set<String>
    let hostWidePorts: Set<Int>
    let hostWideCompleteness: PortScanCompleteness

    init(
        output: String,
        trackedTTYNames: Set<String>,
        completionMarker: String,
        hostWidePortMarker: String,
        hostWideCompletionMarker: String
    ) {
        var ports = Dictionary(uniqueKeysWithValues: trackedTTYNames.map { ($0, Set<Int>()) })
        var completeTTYNames: Set<String> = []
        var hostWidePorts: Set<Int> = []
        var hostWideCompleteness = PortScanCompleteness.incomplete

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count == 1,
               String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    == hostWideCompletionMarker {
                hostWideCompleteness = .complete
                continue
            }
            guard parts.count == 2 else { continue }
            let first = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let second = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if first == completionMarker, trackedTTYNames.contains(second) {
                completeTTYNames.insert(second)
                continue
            }
            if first == hostWidePortMarker,
               let port = Int(second),
               port >= 1024,
               port <= 65_535 {
                hostWidePorts.insert(port)
                continue
            }
            guard trackedTTYNames.contains(first),
                  let port = Int(second),
                  port >= 1024,
                  port <= 65_535 else {
                continue
            }
            ports[first, default: []].insert(port)
        }

        portsByTTY = ports.mapValues { $0.sorted() }
        self.completeTTYNames = completeTTYNames
        self.hostWidePorts = hostWidePorts
        self.hostWideCompleteness = hostWideCompleteness
    }
}
