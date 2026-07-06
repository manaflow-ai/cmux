import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    func requestTerminalEventPing(
        client: MobileCoreRPCClient,
        nonce: String,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let requestData: Data
        do {
            requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.ping",
                params: [
                    "stream_id": terminalEventStreamID,
                    "topic": terminalEventPongTopic,
                    "nonce": nonce,
                ]
            )
        } catch {
            return false
        }
        do {
            let responseData = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: timeoutNanoseconds
            )
            let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            return (response?["delivered"] as? Bool) == true
        } catch {
            return false
        }
    }

    func finishTerminalEventPong(nonce: String, delivered: Bool) {
        terminalEventPongTimersByNonce.removeValue(forKey: nonce)?.cancel()
        guard let continuation = terminalEventPongContinuationsByNonce.removeValue(forKey: nonce) else {
            return
        }
        continuation.resume(returning: delivered)
    }

    func cancelTerminalEventPongWaiters() {
        let nonces = Array(terminalEventPongContinuationsByNonce.keys)
        for nonce in nonces {
            finishTerminalEventPong(nonce: nonce, delivered: false)
        }
    }

    func verifyTerminalEventStreamDelivery(
        client: MobileCoreRPCClient,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let nonce = UUID().uuidString
        return await withCheckedContinuation { continuation in
            terminalEventPongContinuationsByNonce[nonce] = continuation
            let timer = DispatchSource.makeTimerSource(queue: .main)
            terminalEventPongTimersByNonce[nonce] = timer
            timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds)))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishTerminalEventPong(nonce: nonce, delivered: false)
                }
            }
            timer.resume()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pingSent = await self.requestTerminalEventPing(
                    client: client,
                    nonce: nonce,
                    timeoutNanoseconds: timeoutNanoseconds
                )
                if !pingSent {
                    self.finishTerminalEventPong(nonce: nonce, delivered: false)
                }
            }
        }
    }

    func handleTerminalEventPong(_ event: MobileEventEnvelope) {
        guard let json = event.payloadJSON,
              let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let nonce = payload["nonce"] as? String else {
            return
        }
        finishTerminalEventPong(nonce: nonce, delivered: true)
    }
}
