import Foundation
import os

/// Copies bytes both ways between a phone lane and a host socket until
/// either side ends, then closes both. Used for acpmux attachment
/// transfers, whose bytes the Mac does not interpret.
actor ByteLaneRelay {
    private let phone: any MobileByteLane
    private let host: any MobileByteLane
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.acpmux-transfer")
    static let chunkBytes = 256 * 1024

    init(phone: any MobileByteLane, host: any MobileByteLane) {
        self.phone = phone
        self.host = host
    }

    /// Runs until one side closes; returns whether the phone side ended first.
    func run() async -> Bool {
        let phoneEnded = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await Self.pump(from: self.phone, to: self.host); return true }
            group.addTask { await Self.pump(from: self.host, to: self.phone); return false }
            let first = await group.next() ?? true
            group.cancelAll()
            await phone.close()
            await host.close()
            return first
        }
        logger.info("acpmux transfer ended (phone first: \(phoneEnded, privacy: .public))")
        return phoneEnded
    }

    private static func pump(from source: any MobileByteLane, to sink: any MobileByteLane) async {
        do {
            // wakeup-allow: awaits the next chunk; ends when the source closes (nil)
            while let chunk = try await source.read(maximumBytes: chunkBytes) {
                try await sink.write(chunk)
            }
        } catch {}
    }
}
