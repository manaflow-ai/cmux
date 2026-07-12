import CMUXMobileCore
import Foundation

struct TerminalScrollRequest: Equatable, Sendable {
    enum WireEncoding: Equatable, Sendable {
        case legacyScalar
        case orderedRuns
    }

    /// Keeps gesture memory bounded independently from the smaller per-RPC host budget.
    static let maximumJournalRunCount = 256

    let surfaceID: String
    var interactionEpoch: UInt64
    var clientRevision: UInt64
    var lines: Double
    var col: Int
    var row: Int
    var prefetchWindow: TerminalScrollPrefetchWindow?
    var directionalRuns: [MobileTerminalScrollRun]
    var wireEncoding: WireEncoding

    init(
        surfaceID: String,
        interactionEpoch: UInt64,
        clientRevision: UInt64,
        lines: Double,
        col: Int,
        row: Int,
        prefetchWindow: TerminalScrollPrefetchWindow?
    ) {
        self.surfaceID = surfaceID
        self.interactionEpoch = interactionEpoch
        self.clientRevision = clientRevision
        self.lines = lines
        self.col = col
        self.row = row
        self.prefetchWindow = prefetchWindow
        self.directionalRuns = lines == 0
            ? []
            : [MobileTerminalScrollRun(lines: lines, col: col, row: row)]
        self.wireEncoding = .legacyScalar
    }

    mutating func append(_ newer: Self) -> Bool {
        precondition(surfaceID == newer.surfaceID)
        precondition(interactionEpoch == newer.interactionEpoch)

        var requiredRunCount = directionalRuns.count
        var previousRun = directionalRuns.last
        for run in newer.directionalRuns {
            if previousRun.map({ Self.canCoalesce($0, run) }) != true {
                requiredRunCount += 1
            }
            guard requiredRunCount <= Self.maximumJournalRunCount else {
                return false
            }
            previousRun = run
        }

        for run in newer.directionalRuns {
            if let lastIndex = directionalRuns.indices.last,
               Self.canCoalesce(directionalRuns[lastIndex], run) {
                directionalRuns[lastIndex].lines += run.lines
            } else {
                directionalRuns.append(run)
            }
        }
        lines += newer.lines
        clientRevision = newer.clientRevision
        col = newer.col
        row = newer.row
        if let newerWindow = newer.prefetchWindow {
            prefetchWindow = newerWindow
        }
        return true
    }

    /// Converts one bounded gesture journal into ordered host calls.
    func plannedRPCRequests(supportsOrderedRuns: Bool) -> [Self] {
        let batchSize = supportsOrderedRuns
            ? MobileTerminalScrollRun.maximumOrderedBatchCount
            : 1
        let encoding: WireEncoding = supportsOrderedRuns ? .orderedRuns : .legacyScalar
        guard !directionalRuns.isEmpty else {
            var request = self
            request.wireEncoding = encoding
            return [request]
        }

        var requests: [Self] = []
        requests.reserveCapacity((directionalRuns.count + batchSize - 1) / batchSize)
        var startIndex = 0
        while startIndex < directionalRuns.count {
            let endIndex = min(startIndex + batchSize, directionalRuns.count)
            let runs = Array(directionalRuns[startIndex..<endIndex])
            var request = self
            request.directionalRuns = runs
            request.lines = runs.reduce(0) { $0 + $1.lines }
            request.col = runs.last?.col ?? col
            request.row = runs.last?.row ?? row
            request.prefetchWindow = endIndex == directionalRuns.count ? prefetchWindow : nil
            request.wireEncoding = encoding
            requests.append(request)
            startIndex = endIndex
        }
        return requests
    }

    static func canCoalesce(
        _ older: MobileTerminalScrollRun,
        _ newer: MobileTerminalScrollRun
    ) -> Bool {
        older.lines.sign == newer.lines.sign
            && older.col == newer.col
            && older.row == newer.row
    }
}
