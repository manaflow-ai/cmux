import AppKit

/// Presents an app-owned companion above normal windows without activating
/// its application. The companion stays visible when another app activates,
/// and belongs to the Space where it is presented.
@MainActor
struct ExternalWindowCompanionPresenter {
    typealias OrderWindow = @MainActor (_ companionWindow: NSWindow) -> Void

    private let orderWindow: OrderWindow

    init(
        orderWindow: @escaping OrderWindow = { companionWindow in
            companionWindow.orderFrontRegardless()
        }
    ) {
        self.orderWindow = orderWindow
    }

    func present(_ companionWindow: NSWindow) {
        companionWindow.level = .floating
        companionWindow.collectionBehavior = [.managed]
        companionWindow.hidesOnDeactivate = false
        orderWindow(companionWindow)
    }
}
