#if canImport(UIKit)
import CMUXMobileCore
import UIKit

/// Bridges UIKit input callbacks and chrome commands to async RPC actions.
///
/// Frames deliberately do NOT flow through here: the store consumes the
/// decoder stream for the subscription's lifetime and publishes
/// `state.latestFrame`, so a SwiftUI remount can never kill the frame
/// pipeline. This coordinator only carries input out of the content view.
@MainActor
final class BrowserStreamSurfaceCoordinator: BrowserStreamContentViewDelegate {
    private let panelID: String
    private let actions: BrowserStreamSurfaceActions

    init(panelID: String, actions: BrowserStreamSurfaceActions) {
        self.panelID = panelID
        self.actions = actions
    }

    func attach(to view: BrowserStreamContentView) {
        view.delegate = self
        view.panelID = panelID
    }

    func perform(_ command: BrowserStreamSurfaceState.ChromeCommand) {
        Task {
            switch command {
            case .back: await actions.back(panelID)
            case .forward: await actions.forward(panelID)
            case .reload: await actions.reload(panelID)
            case let .navigate(url): await actions.navigate(panelID, url)
            }
        }
    }

    func browserStreamContentView(_ view: BrowserStreamContentView, didProducePointer input: MobileBrowserPointerInput) {
        Task { await actions.pointer(input) }
    }

    func browserStreamContentView(_ view: BrowserStreamContentView, didProduceScroll input: MobileBrowserScrollInput) {
        Task { await actions.scroll(input) }
    }

    func browserStreamContentView(_ view: BrowserStreamContentView, didProduceKey input: MobileBrowserKeyInput) {
        Task { await actions.key(input) }
    }

    func browserStreamContentView(_ view: BrowserStreamContentView, didProduceText input: MobileBrowserTextInput) {
        Task { await actions.text(input) }
    }

    func browserStreamContentView(_ view: BrowserStreamContentView, didChangeViewport viewport: MobileBrowserViewport) {
        let parameters = MobileBrowserViewportParameters(panelID: panelID, viewport: viewport)
        Task { await actions.viewport(parameters) }
    }
}
#endif
