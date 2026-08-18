import Darwin
import Foundation

/// Computes a conservative file-descriptor allowance for executable watches.
struct SharedLiveAgentForkExecutableWatchDescriptorBudget: Sendable {
    private let maximumSourceCount = 64
    private let minimumReservedDescriptorCount = 128
    private let rlimInfinity = rlim_t(Int64.max)

    func sourceCount(
        softFileDescriptorLimit explicitSoftLimit: Int? = nil,
        openFileDescriptorCount explicitOpenFileDescriptorCount: Int? = nil,
        pendingReservationCount: Int = 0
    ) -> Int {
        guard let softLimit = softFileDescriptorLimit(explicitSoftLimit),
              let openCount = explicitOpenFileDescriptorCount
                ?? currentOpenFileDescriptorCount() else {
            return 0
        }
        let available = availableDescriptorCount(
            softFileDescriptorLimit: softLimit,
            openFileDescriptorCount: openCount,
            pendingReservationCount: pendingReservationCount
        )
        guard available > 0 else { return 0 }
        return min(maximumSourceCount, max(1, available / 4))
    }

    func reserveIsSatisfied(
        pendingReservationCount: Int,
        softFileDescriptorLimit explicitSoftLimit: Int? = nil,
        openFileDescriptorCount explicitOpenFileDescriptorCount: Int? = nil
    ) -> Bool {
        guard let softLimit = softFileDescriptorLimit(explicitSoftLimit),
              let openCount = explicitOpenFileDescriptorCount
                ?? currentOpenFileDescriptorCount() else {
            return false
        }
        return availableDescriptorCount(
            softFileDescriptorLimit: softLimit,
            openFileDescriptorCount: openCount,
            pendingReservationCount: pendingReservationCount
        ) >= 0
    }

    private func availableDescriptorCount(
        softFileDescriptorLimit: Int,
        openFileDescriptorCount: Int,
        pendingReservationCount: Int
    ) -> Int {
        softFileDescriptorLimit
            - openFileDescriptorCount
            - pendingReservationCount
            - minimumReservedDescriptorCount
    }

    private func softFileDescriptorLimit(_ explicitLimit: Int?) -> Int? {
        if let explicitLimit { return explicitLimit }
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0,
              limit.rlim_cur != rlimInfinity,
              limit.rlim_cur <= rlim_t(Int.max) else {
            return nil
        }
        return Int(limit.rlim_cur)
    }

    private func currentOpenFileDescriptorCount() -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return nil
        }
        return names.compactMap(Int.init).count
    }
}
