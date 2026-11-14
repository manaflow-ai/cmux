import CmuxNextCompat
import CmuxNextRemoteView
import CmuxScreenKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct MacScreenViewerFallbackTests {
    nonisolated final class Worker: MacScreenRdWorker {
        let lines: AsyncStream<MacScreenRdMessage>
        let output: AsyncStream<MacScreenRdMessage>.Continuation
        private let state = Mutex((started: false, stops: 0))
        var started: Bool { state.load().started }
        var stops: Int { state.load().stops }
        var stderrTail: String { "" }
        init() { (lines, output) = AsyncStream.makeStream(of: MacScreenRdMessage.self) }
        func start(_ role: MacScreenRdProcess.Role) { state.withLock { $0.started = true } }
        func send<Value: Encodable>(_ value: Value) {}
        // Closing stdin does not finish stdout; the final decision can still be buffered there.
        func stop() { state.withLock { $0.stops += 1 } }
        func emit(_ json: String) throws {
            let reader = try #require(RemoteRdLineReader())
            output.yield(try #require(reader.push(Data((json + "\n").utf8)).first))
        }
    }

    nonisolated final class Signaling: ScreenSignaling {
        private let stream: AsyncThrowingStream<ScreenSignal, any Error>
        let input: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
        private let readers = Mutex(0)
        let opened: AsyncStream<Void>
        private let openedSignal: AsyncStream<Void>.Continuation
        var readerCount: Int { readers.load() }
        init() {
            (stream, input) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self)
            (opened, openedSignal) = AsyncStream.makeStream(of: Void.self)
        }
        func messages() -> AsyncThrowingStream<ScreenSignal, any Error> {
            readers.withLock { $0 += 1 }
            openedSignal.yield(())
            return stream
        }
        func send(_ signal: ScreenSignal) async throws {}
        func iceServers() async throws -> [ICEServerConfig] { [] }
        func close() { input.finish() }
        var endsSessionOnClose: Bool { true }
    }

    private let fallback = #"{"fallback":{"carrier":"rd_wg","reason":"timeout","retry":"web_rtc"}}"#

    @Test func socketEOFFirstPreservesTheWorkersFallback() async throws {
        let worker = Worker(), signaling = Signaling()
        let session = MacScreenSession(title: "Host", preferences: ScreenPreferences(), signaling: { signaling })
        var starts = 0
        session.startFallback = { _ in starts += 1 }
        defer { session.close(); signaling.close() }
        let output = try #require(session.connect(worker: worker))
        var opened = signaling.opened.makeAsyncIterator()
        _ = await opened.next()
        session.transportEnded(.connectionLost)
        #expect(session.phase == .connecting)
        #expect(worker.stops == 1)
        try worker.emit(fallback)
        worker.output.finish()
        await output.value
        #expect(starts == 1)
        #expect(signaling.readerCount == 1)
        #expect(session.streamPath.hasPrefix("WebRTC"))
    }

    @Test(arguments: [false, true])
    func socketEOFFirstStillEndsWhenWorkerHasNoFallback(explicitEnd: Bool) async throws {
        let worker = Worker(), signaling = Signaling()
        let session = MacScreenSession(title: "Host", preferences: ScreenPreferences(), signaling: { signaling })
        var starts = 0
        session.startFallback = { _ in starts += 1 }
        defer { session.close(); signaling.close() }
        let output = try #require(session.connect(worker: worker))
        var opened = signaling.opened.makeAsyncIterator()
        _ = await opened.next()
        session.transportEnded(.connectionLost)
        if explicitEnd { try worker.emit(#"{"ended":"revoked"}"#) }
        worker.output.finish()
        await output.value
        if case .failed = session.phase {} else { Issue.record("worker terminal outcome did not end the session") }
        #expect(starts == 0)
    }

    @Test(arguments: [false, true])
    func stopOrRestartRejectsTheOldFallback(restart: Bool) async throws {
        let worker = Worker(), signaling = Signaling()
        let session = MacScreenSession(title: "Host", preferences: ScreenPreferences(), signaling: { signaling })
        var starts = 0
        session.startFallback = { _ in starts += 1 }
        defer { session.close(); signaling.close() }
        let oldOutput = try #require(session.connect(worker: worker))
        session.transportEnded(.connectionLost)
        session.close()
        let next = Worker()
        let newOutput = restart ? session.connect(worker: next) : nil
        try worker.emit(fallback)
        worker.output.finish()
        await oldOutput.value
        #expect(starts == 0)
        if restart { #expect(session.phase == .connecting) }
        session.close()
        next.output.finish()
        await newOutput?.value
    }

    @Test func finalWorkerLineIsDrainedBeforeProcessExitCompletesOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("worker")
        try Data(("#!/bin/sh\nprintf '%s\\n' '" + fallback + "'\n").utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        for _ in 0..<16 {
            let worker = MacScreenRdProcess(binary: binary)
            try worker.start(.connect)
            var decisions = 0
            for await line in worker.lines { if line.fallbackToWebRTC { decisions += 1 } }
            #expect(decisions == 1)
        }
    }
}
