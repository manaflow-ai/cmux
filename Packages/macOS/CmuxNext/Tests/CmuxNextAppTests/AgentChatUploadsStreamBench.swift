import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Testing

/// How long the main thread is held while a large file streams into a chat on this Mac: the page's
/// `chat.upload.chunk` requests, decoded as the bridge decodes them (``AgentPaneRequest``), through
/// the stager the app wires for a local chat (``AgentChatUploads/stager(tab:services:)``). Leo,
/// 2026-10-25: "arbitarrily large file sizes the composer should never ever freeze". A background
/// thread pings the main queue every millisecond, and each ping's lateness is how long the main
/// thread was busy. Run on the fleet (not in CI): `CMUX_PANE_TRANSPORT_BENCH=1`, suite
/// `AgentChatUploadsStreamBench`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_TRANSPORT_BENCH"] == "1"))
@MainActor
struct AgentChatUploadsStreamBench {
    private static let chunkBytes = 512 * 1024
    private static let chunks = 512

    @Test func streamingAFileLeavesTheMainThreadFree() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", session = UUID().uuidString.lowercased()
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        services.agentTabs.sessions[tab] = session
        let stager = try #require(AgentChatUploads.stager(tab: tab, services: services))
        func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            guard case .uploadStage(let stage) = AgentPaneRequest(body: ["method": method, "params": params]) else {
                throw CancellationError()
            }
            return await stager(stage, session)
        }

        let size = Self.chunks * Self.chunkBytes
        let begun = try await send("chat.upload.begin", ["name": "movie.mov", "size": size])
        let token = try #require((begun["value"] as? [String: Any])?["token"] as? String, "\(begun)")
        let chunk = Data(repeating: 0x5A, count: Self.chunkBytes).base64EncodedString()
        let probe = MainThreadProbe()
        let before = ProcessUsage.sample(getpid())?.physFootprint ?? 0
        var peak = before
        let started = ContinuousClock.now
        probe.start()
        for index in 0..<Self.chunks {
            let offset = index * Self.chunkBytes
            let wrote = try await send("chat.upload.chunk", ["token": token, "offset": offset, "data": chunk])
            #expect((wrote["value"] as? [String: Any])?["offset"] as? Int == offset + Self.chunkBytes, "\(wrote)")
            peak = max(peak, ProcessUsage.sample(getpid())?.physFootprint ?? 0)
        }
        let late = probe.stop().sorted()
        let elapsed = started.duration(to: .now)
        _ = try await send("chat.upload.cancel", ["token": token])

        let p50 = late.isEmpty ? .zero : late[late.count / 2], p99 = late.isEmpty ? .zero : late[late.count * 99 / 100]
        let growth = Int64(peak) - Int64(before)
        print("AGENT-UPLOAD-STREAM-BENCH chunks=\(Self.chunks) bytes=\(size) elapsed=\(elapsed) pings=\(late.count) "
            + "main_late_p50=\(p50) main_late_p99=\(p99) main_late_max=\(late.last ?? .zero) footprint_growth=\(growth)")
        #expect(!late.isEmpty, "the probe never reached the main thread")
        #expect(p99 < .milliseconds(4), "the main thread was held \(p99) at p99")
        #expect(growth < Int64(64 * 1024 * 1024), "memory grew \(growth) bytes for \(size) streamed")
    }

    /// Pings the main queue from a background thread every millisecond and records how late each
    /// ping ran: how long the main thread was busy.
    private nonisolated final class MainThreadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var late: [Duration] = []
        private var running = true

        func start() {
            Thread { [self] in
                while lock.withLock({ running }) {
                    let sent = ContinuousClock.now
                    DispatchQueue.main.async { [self] in
                        let waited = sent.duration(to: .now)
                        lock.withLock { if running { late.append(waited) } }
                    }
                    usleep(1000)
                }
            }.start()
        }

        func stop() -> [Duration] {
            lock.withLock {
                running = false
                return late
            }
        }
    }
}
