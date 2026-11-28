import CMUXMobileCore
import CoreGraphics

/// Preserves native gesture boundaries while coalescing movement to one batch per display frame.
struct BrowserStreamScrollBatcher: Equatable, Sendable {
    private var phasePolicy = BrowserStreamScrollPhasePolicy()
    private var pending: [BrowserStreamScrollBatch] = []

    mutating func consume(
        _ event: BrowserStreamScrollPhasePolicy.Event,
        delta: CGPoint = .zero
    ) {
        guard let phase = phasePolicy.consume(event) else { return }
        switch phase {
        case .changed:
            mergeOrAppend(delta: delta, phase: phase, compatiblePredecessor: .began)
        case .momentumChanged:
            mergeOrAppend(delta: delta, phase: phase, compatiblePredecessor: .momentumBegan)
        default:
            pending.append(BrowserStreamScrollBatch(delta: delta, phase: phase))
        }
    }

    mutating func next() -> BrowserStreamScrollBatch? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    mutating func reset() {
        phasePolicy = BrowserStreamScrollPhasePolicy()
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func mergeOrAppend(
        delta: CGPoint,
        phase: MobileBrowserScrollPhase,
        compatiblePredecessor: MobileBrowserScrollPhase
    ) {
        guard delta != .zero else { return }
        if let index = pending.indices.last,
           pending[index].phase == phase || pending[index].phase == compatiblePredecessor {
            pending[index].delta.x += delta.x
            pending[index].delta.y += delta.y
        } else {
            pending.append(BrowserStreamScrollBatch(delta: delta, phase: phase))
        }
    }
}
