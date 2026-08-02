import CmuxSimulator

enum SimulatorPaneOutgoingItem: Sendable {
    case message(SimulatorWorkerInbound, tracksLiveInput: Bool)
    case deliveryBarrier(SimulatorOutgoingDeliveryReceipt)
}
