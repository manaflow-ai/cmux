#if canImport(UIKit)
import CMUXMobileCore
import UIKit

/// Bridges decoded frames and UIKit input callbacks to async RPC actions.
@MainActor
final class BrowserStreamSurfaceCoordinator: BrowserStreamContentViewDelegate {
    private let panelID: String
    private let frames: AsyncStream<BrowserStreamFrame>
    private let actions: BrowserStreamSurfaceActions
    private let didDisplay: @MainActor (BrowserStreamFrame) -> Void
    private var frameTask: Task<Void, Never>?

    init(
        panelID: String,
        frames: AsyncStream<BrowserStreamFrame>,
        actions: BrowserStreamSurfaceActions,
        didDisplay: @escaping @MainActor (BrowserStreamFrame) -> Void
    ) {
        self.panelID = panelID
        self.frames = frames
        self.actions = actions
        self.didDisplay = didDisplay
    }

    deinit {
        frameTask?.cancel()
    }

    func attach(to view: BrowserStreamContentView) {
        view.delegate = self
        view.panelID = panelID
        frameTask?.cancel()
        frameTask = Task { @MainActor [weak view] in
            for await frame in frames {
                guard !Task.isCancelled, let view else { return }
                view.display(frame)
                didDisplay(frame)
            }
        }
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
}
#endif
