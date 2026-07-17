public import CMUXMobileCore
public import Foundation
import Observation

/// Observable, read-only terminal-tail projection for Pane Rack strips and rows.
@MainActor
@Observable
public final class PaneTailStore {
    /// Published tails keyed by terminal surface identifier.
    public private(set) var tails: [String: PaneTail] = [:]

    @ObservationIgnored private weak var replayRequester: (any PaneTailReplayRequesting)?
    @ObservationIgnored private let now: @MainActor @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var interestedSurfaceIDs: Set<String> = []
    @ObservationIgnored private var rowsBySurfaceID: [String: [String]] = [:]
    @ObservationIgnored private var columnsBySurfaceID: [String: Int] = [:]
    @ObservationIgnored private var activityBySurfaceID: [String: Date] = [:]
    @ObservationIgnored private var rowBudgetBySurfaceID: [String: Int] = [:]
    @ObservationIgnored private var dirtySurfaceIDs: Set<String> = []
    @ObservationIgnored private var lastPublishedAtBySurfaceID: [String: Date] = [:]
    @ObservationIgnored private var publishTasksBySurfaceID: [String: Task<Void, Never>] = [:]

    private static let defaultRowBudget = 3
    private static let minimumPublishInterval: TimeInterval = 0.1

    /// Creates a terminal-tail store with injectable time and delay seams.
    /// - Parameters:
    ///   - now: Supplies activity and throttling timestamps.
    ///   - sleep: Performs the cancellable coalescing delay between publications.
    public init(
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    isolated deinit {
        for task in publishTasksBySurfaceID.values {
            task.cancel()
        }
    }

    /// Replaces the set of surfaces whose tails the UI currently consumes.
    ///
    /// Newly interested surfaces request an authoritative replay. Removed
    /// surfaces immediately discard buffered and published content.
    /// - Parameter surfaceIDs: Terminal surface identifiers currently visible in the rack.
    public func setInterest(_ surfaceIDs: Set<String>) {
        let added = surfaceIDs.subtracting(interestedSurfaceIDs)
        let removed = interestedSurfaceIDs.subtracting(surfaceIDs)
        interestedSurfaceIDs = surfaceIDs

        for surfaceID in removed {
            publishTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
            rowsBySurfaceID.removeValue(forKey: surfaceID)
            columnsBySurfaceID.removeValue(forKey: surfaceID)
            activityBySurfaceID.removeValue(forKey: surfaceID)
            rowBudgetBySurfaceID.removeValue(forKey: surfaceID)
            dirtySurfaceIDs.remove(surfaceID)
            lastPublishedAtBySurfaceID.removeValue(forKey: surfaceID)
            tails.removeValue(forKey: surfaceID)
        }
        for surfaceID in added.sorted() {
            replayRequester?.requestPaneTailReplay(surfaceID: surfaceID)
        }
    }

    /// Sets the published row budget for one surface, such as while peeking.
    /// - Parameters:
    ///   - surfaceID: Terminal surface identifier.
    ///   - rows: Maximum non-blank rows to publish. Values below three restore the default.
    public func setPeekBudget(surfaceID: String, rows: Int) {
        let budget = max(Self.defaultRowBudget, rows)
        if budget == Self.defaultRowBudget {
            rowBudgetBySurfaceID.removeValue(forKey: surfaceID)
        } else {
            rowBudgetBySurfaceID[surfaceID] = budget
        }
        guard interestedSurfaceIDs.contains(surfaceID), rowsBySurfaceID[surfaceID] != nil else { return }
        dirtySurfaceIDs.insert(surfaceID)
        publishOrSchedule(surfaceID: surfaceID)
    }

    /// Applies one full or delta render-grid frame when its surface is interesting.
    /// - Parameter frame: The decoded render-grid frame.
    /// - Returns: `true` when the frame belonged to the current interest set.
    @discardableResult
    public func apply(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard interestedSurfaceIDs.contains(frame.surfaceID) else { return false }
        var rows = rowsBySurfaceID[frame.surfaceID] ?? []
        if frame.full {
            rows = frame.plainRows()
        } else {
            resizeRows(&rows, count: frame.rows)
            for row in frame.clearedRows where rows.indices.contains(row) {
                rows[row] = ""
            }
            let projectedRows = frame.plainRows()
            for row in Set(frame.rowSpans.map(\.row)) where rows.indices.contains(row) {
                rows[row] = projectedRows[row]
            }
        }
        resizeRows(&rows, count: frame.rows)
        rowsBySurfaceID[frame.surfaceID] = rows
        columnsBySurfaceID[frame.surfaceID] = frame.columns
        let deliveredAt = now()
        activityBySurfaceID[frame.surfaceID] = max(
            activityBySurfaceID[frame.surfaceID] ?? .distantPast,
            deliveredAt
        )
        dirtySurfaceIDs.insert(frame.surfaceID)
        publishOrSchedule(surfaceID: frame.surfaceID)
        return true
    }

    /// Returns whether a surface currently belongs to the interest set.
    /// - Parameter surfaceID: Terminal surface identifier.
    /// - Returns: `true` when frames for the surface should be decoded and merged.
    public func isInterested(in surfaceID: String) -> Bool {
        interestedSurfaceIDs.contains(surfaceID)
    }

    func installReplayRequester(_ requester: any PaneTailReplayRequesting) {
        replayRequester = requester
    }

    func flushPendingPublications() {
        for surfaceID in dirtySurfaceIDs.sorted() {
            publishTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
            publishIfThrottleAllows(surfaceID: surfaceID)
        }
    }

    private func publishOrSchedule(surfaceID: String) {
        guard let lastPublishedAt = lastPublishedAtBySurfaceID[surfaceID] else {
            publish(surfaceID: surfaceID, at: now())
            return
        }
        let elapsed = now().timeIntervalSince(lastPublishedAt)
        if elapsed >= Self.minimumPublishInterval {
            publish(surfaceID: surfaceID, at: now())
            return
        }
        guard publishTasksBySurfaceID[surfaceID] == nil else { return }
        let remaining = Self.minimumPublishInterval - max(0, elapsed)
        let delay = Duration.nanoseconds(Int64((remaining * 1_000_000_000).rounded(.up)))
        publishTasksBySurfaceID[surfaceID] = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                self?.publishTasksBySurfaceID.removeValue(forKey: surfaceID)
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.publishTasksBySurfaceID.removeValue(forKey: surfaceID)
            self.publishIfThrottleAllows(surfaceID: surfaceID)
        }
    }

    private func publishIfThrottleAllows(surfaceID: String) {
        let timestamp = now()
        if let lastPublishedAt = lastPublishedAtBySurfaceID[surfaceID],
           timestamp.timeIntervalSince(lastPublishedAt) < Self.minimumPublishInterval {
            publishOrSchedule(surfaceID: surfaceID)
            return
        }
        publish(surfaceID: surfaceID, at: timestamp)
    }

    private func publish(surfaceID: String, at timestamp: Date) {
        guard dirtySurfaceIDs.remove(surfaceID) != nil,
              interestedSurfaceIDs.contains(surfaceID),
              let bufferedRows = rowsBySurfaceID[surfaceID] else { return }
        let budget = rowBudgetBySurfaceID[surfaceID] ?? Self.defaultRowBudget
        let nonBlankRows = bufferedRows.compactMap { row -> String? in
            let trimmed = trimmingTrailingWhitespace(row)
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmed
        }
        tails[surfaceID] = PaneTail(
            rows: Array(nonBlankRows.suffix(budget)),
            lastActivityAt: activityBySurfaceID[surfaceID],
            columns: columnsBySurfaceID[surfaceID] ?? 0
        )
        lastPublishedAtBySurfaceID[surfaceID] = timestamp
    }

    private func resizeRows(_ rows: inout [String], count: Int) {
        if rows.count > count {
            rows.removeLast(rows.count - count)
        } else if rows.count < count {
            rows.append(contentsOf: repeatElement("", count: count - rows.count))
        }
    }

    private func trimmingTrailingWhitespace(_ value: String) -> String {
        var result = value
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }
}
