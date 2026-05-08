import Foundation

@MainActor
public protocol CmxTerminalSessionDelegate: AnyObject {
    func terminalSession(_ session: any CmxTerminalSession, didReceive message: CmxServerMessage)
    func terminalSession(_ session: any CmxTerminalSession, didUpdateLatencyMilliseconds latencyMilliseconds: UInt32)
    func terminalSession(_ session: any CmxTerminalSession, didFail error: Error)
    func terminalSessionDidClose(_ session: any CmxTerminalSession)
}

public extension CmxTerminalSessionDelegate {
    func terminalSession(_ session: any CmxTerminalSession, didUpdateLatencyMilliseconds latencyMilliseconds: UInt32) {}
}

@MainActor
public protocol CmxTerminalSession: AnyObject {
    var delegate: CmxTerminalSessionDelegate? { get set }

    func start(viewport: CmxWireViewport)
    func sendInput(_ data: Data, terminalID: UInt64)
    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64)
    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport])
    func requestPtyReplay(terminalID: UInt64)
    func sendCommand(_ command: CmxClientCommand)
    func disconnect()
}

public enum CmxHeartbeatAction: Equatable {
    case sendPing
    case waitForPong
    case timedOut(elapsedSeconds: TimeInterval)
}

public struct CmxHeartbeatState {
    public var pendingPingSentAt: Date?
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public mutating func tick(now: Date = Date()) -> CmxHeartbeatAction {
        guard let pendingPingSentAt else {
            self.pendingPingSentAt = now
            return .sendPing
        }
        let elapsed = now.timeIntervalSince(pendingPingSentAt)
        if elapsed >= timeout {
            return .timedOut(elapsedSeconds: elapsed)
        }
        return .waitForPong
    }

    public mutating func recordPong(now: Date = Date()) -> UInt32? {
        guard let pendingPingSentAt else { return nil }
        self.pendingPingSentAt = nil
        let elapsedMilliseconds = max(0, now.timeIntervalSince(pendingPingSentAt) * 1_000)
        return UInt32(clamping: Int(elapsedMilliseconds.rounded()))
    }

    public mutating func reset() {
        pendingPingSentAt = nil
    }
}
