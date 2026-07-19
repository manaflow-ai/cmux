import Foundation

/// Parsed positive port evidence and authoritative completion scopes from one TTY scan.
struct RemoteTTYPortScanOutput: Sendable, Equatable {
    let portsByTTY: [String: [Int]]
    let completeTTYNames: Set<String>

    init(
        output: String,
        trackedTTYNames: Set<String>,
        completionMarker: String
    ) {
        var ports = Dictionary(uniqueKeysWithValues: trackedTTYNames.map { ($0, Set<Int>()) })
        var completeTTYNames: Set<String> = []

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let first = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let second = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if first == completionMarker, trackedTTYNames.contains(second) {
                completeTTYNames.insert(second)
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
    }
}
