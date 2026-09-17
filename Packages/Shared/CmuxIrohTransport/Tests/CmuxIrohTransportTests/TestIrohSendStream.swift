import Foundation
@testable import CmuxIrohTransport

actor TestIrohSendStream: CmxIrohSendStream {
    private let eventRecorder: TestIrohEventRecorder?
    private let eventName: String?
    private var sentBuffers: [Data] = []
    private var finishCallCount = 0
    private var resetCodes: [UInt64] = []
    private var priorities: [Int32] = []

    init(
        eventRecorder: TestIrohEventRecorder? = nil,
        eventName: String? = nil
    ) {
        self.eventRecorder = eventRecorder
        self.eventName = eventName
    }

    func send(_ data: Data) async {
        sentBuffers.append(data)
        if let eventName {
            await eventRecorder?.record(eventName)
        }
    }

    func finish() {
        finishCallCount += 1
    }

    func reset(errorCode: UInt64) {
        resetCodes.append(errorCode)
    }

    func setPriority(_ priority: Int32) {
        priorities.append(priority)
    }

    func observedSentBuffers() -> [Data] {
        sentBuffers
    }

    func observedResetCodes() -> [UInt64] {
        resetCodes
    }

    func observedPriorities() -> [Int32] {
        priorities
    }
}
