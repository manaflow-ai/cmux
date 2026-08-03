#if DEBUG
import AppKit

struct SpinnerSpec {
    let title: String
    let mechanism: String
    let energy: SpinnerEnergy
    let shipping: Bool
    let makeView: @MainActor () -> NSView
}
#endif
