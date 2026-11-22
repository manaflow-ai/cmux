public import Foundation
import os

/// Pipes an admitted phone's daemon lane to a daemon socket through
/// `DaemonLanePolicy`.
///
/// Both directions are split into lines so a refusal can be injected between
/// daemon lines without corrupting either stream. Phone to daemon, every line
/// is judged; daemon to phone, lines pass through unchanged. The splice owns
/// both lanes and closes both when either side ends, which makes the daemon
/// drop the phone's geometry leases and streams.
public actor DaemonLaneSplice {
    /// Daemon lines may carry a full VT replay (the daemon caps them at 32 MiB).
    public static let maximumDaemonLineBytes = 64 << 20
    static let readChunkBytes = 64 * 1024

    public enum EndReason: Equatable, Sendable {
        case phoneClosed
        case daemonClosed
        case protocolViolation(String)
        case failed(String)
    }

    private let phone: any MobileByteLane
    private let daemon: any MobileByteLane
    private let policy: DaemonLanePolicy
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.daemon-lane")
    private var refusals = 0

    public init(phone: any MobileByteLane, daemon: any MobileByteLane, policy: DaemonLanePolicy) {
        self.phone = phone
        self.daemon = daemon
        self.policy = policy
    }

    /// Commands refused so far (diagnostics, tests).
    public var refusedCount: Int { refusals }

    /// Runs until either side closes; returns why it ended. Both lanes are
    /// closed on return.
    public func run() async -> EndReason {
        let reason = await withTaskGroup(of: EndReason.self) { group in
            group.addTask { await self.pumpPhoneToDaemon() }
            group.addTask { await self.pumpDaemonToPhone() }
            let first = await group.next() ?? .failed("no pump")
            group.cancelAll()
            await phone.close()
            await daemon.close()
            return first
        }
        logger.info("daemon lane ended: \(String(describing: reason), privacy: .public)")
        return reason
    }

    private func pumpPhoneToDaemon() async -> EndReason {
        var splitter = LineSplitter(maximumLineBytes: DaemonLanePolicy.maximumLineBytes)
        do {
            while let chunk = try await phone.read(maximumBytes: Self.readChunkBytes) {
                for line in try splitter.append(chunk) {
                    switch policy.evaluate(line) {
                    case .forward:
                        try await daemon.write(line + Self.newline)
                    case .refuse(let response):
                        refusals += 1
                        try await writeToPhone(response + Self.newline)
                    }
                }
            }
            return .phoneClosed
        } catch let failure as LineSplitter.Failure {
            return .protocolViolation("\(failure)")
        } catch {
            return Task.isCancelled ? .daemonClosed : .failed("phone: \(error)")
        }
    }

    private func pumpDaemonToPhone() async -> EndReason {
        var splitter = LineSplitter(maximumLineBytes: Self.maximumDaemonLineBytes)
        do {
            while let chunk = try await daemon.read(maximumBytes: Self.readChunkBytes) {
                let lines = try splitter.append(chunk)
                guard !lines.isEmpty else { continue }
                var batch = Data()
                for line in lines {
                    batch.append(line)
                    batch.append(Self.newline)
                }
                try await writeToPhone(batch)
            }
            return .daemonClosed
        } catch let failure as LineSplitter.Failure {
            return .protocolViolation("daemon: \(failure)")
        } catch {
            return Task.isCancelled ? .phoneClosed : .failed("daemon: \(error)")
        }
    }

    /// Actor-serialized so a refusal never lands inside a daemon batch.
    private func writeToPhone(_ data: Data) async throws {
        try await phone.write(data)
    }

    static let newline = Data([0x0A])
}
