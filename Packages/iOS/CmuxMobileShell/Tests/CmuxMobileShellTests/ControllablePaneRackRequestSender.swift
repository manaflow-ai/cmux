import CmuxMobileRPC
import Foundation

@testable import CmuxMobileShell

actor ControllablePaneRackRequestSender: PaneRackRequestSending {
    private var requests: [PaneRackRequest] = []
    private var requestWaiters: [CheckedContinuation<PaneRackRequest, Never>] = []
    private var responseContinuations: [CheckedContinuation<Data, any Error>] = []

    func sendPaneRackRequest(_ request: PaneRackRequest) async throws -> Data {
        if requestWaiters.isEmpty {
            requests.append(request)
        } else {
            requestWaiters.removeFirst().resume(returning: request)
        }
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuations.append(continuation)
        }
    }

    func nextRequest() async -> PaneRackRequest {
        if !requests.isEmpty {
            return requests.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func failLastTerminal() {
        responseContinuations.removeFirst().resume(
            throwing: MobileShellConnectionError.rpcError(
                "last_terminal",
                "The workspace's last terminal can't be closed"
            )
        )
    }

    func succeed(with data: Data) {
        responseContinuations.removeFirst().resume(returning: data)
    }
}
