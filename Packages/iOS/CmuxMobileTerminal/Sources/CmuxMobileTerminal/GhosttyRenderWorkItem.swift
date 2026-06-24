#if canImport(UIKit)
import Dispatch

final class GhosttyRenderWorkItem {
    let token: GhosttyRenderCancellationToken
    let dispatchWorkItem: DispatchWorkItem

    init(token: GhosttyRenderCancellationToken, dispatchWorkItem: DispatchWorkItem) {
        self.token = token
        self.dispatchWorkItem = dispatchWorkItem
    }
}
#endif
