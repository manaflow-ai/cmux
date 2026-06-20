import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Answers any framed request with a successful `mobile.attach_ticket.create`
/// response carrying `ticket`, so the manual-host pre-connect probe succeeds.
actor AttachTicketSuccessTransport: CmxByteTransport {
    private let ticket: CmxAttachTicket
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(ticket: CmxAttachTicket) {
        self.ticket = ticket
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            guard let id = parsed?["id"] as? String,
                  let ticketData = try? encoder.encode(ticket),
                  let ticketJSON = try? JSONSerialization.jsonObject(with: ticketData) else { continue }
            let envelope: [String: Any] = ["id": id, "ok": true, "result": ["ticket": ticketJSON]]
            guard let frame = try? MobileSyncFrameCodec.encodeFrame(
                JSONSerialization.data(withJSONObject: envelope)
            ) else { continue }
            deliver(frame)
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        receiveWaiters.removeFirst().resume(returning: frame)
    }
}
