import Foundation

struct TerminalScrollDeliveryCompletion: Equatable, Sendable {
    let next: TerminalScrollDelivery?
    let shouldDeliverScrollPrefetchRenderGrid: Bool
}
