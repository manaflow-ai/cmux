import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

/// The single mount seam for a selected custom sidebar: renders the file
/// through either the remote (out-of-process worker) renderer or the
/// in-process renderer, switching live when the choice changes.
///
/// `remote` is the containment lane: the worker process interprets and
/// renders the file, the host only composites its layer and forwards clicks,
/// so an interpreter fault cannot crash the host. The cost is input fidelity
/// (no hover, focus, or keyboard) and repaint latency.
///
/// In-process mounts ``CmuxSwiftRenderUI/CustomSidebarView`` directly: real
/// SwiftUI in the host window, so native hover/focus/keyboard and same-frame
/// resize work, at the price of sharing the host process with the
/// interpreter. The host chooses via the `customSidebars.renderer` setting
/// (see `CustomSidebarsCatalogSection`); this view stays settings-agnostic
/// and just takes the resolved choice, so the package needs no settings
/// dependency and tests can drive both branches directly.
public struct CustomSidebarSurface: View {
    private let fileURL: URL
    private let dataContext: [String: SwiftValue]
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets
    private let rendersInProcess: Bool
    @Binding private var client: RenderWorkerClient?

    /// Creates the surface.
    ///
    /// - Parameters:
    ///   - fileURL: The `.swift` or `.json` sidebar file to render and watch.
    ///   - dataContext: Live, read-only values the interpreter binds.
    ///   - dispatch: Runs button/tap actions against the host command surface.
    ///   - contentInsets: Top/bottom scroll insets for the host chrome.
    ///   - rendersInProcess: `true` (the default) mounts the in-process
    ///     renderer; `false` mounts the out-of-process worker.
    ///   - client: Window-owned worker client storage for the remote lane,
    ///     so provider switches reuse the live worker instead of paying a
    ///     spawn-and-handshake blank frame (see ``RemoteCustomSidebarHost``).
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        rendersInProcess: Bool = true,
        client: Binding<RenderWorkerClient?>
    ) {
        self.fileURL = fileURL
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        self.rendersInProcess = rendersInProcess
        self._client = client
    }

    public var body: some View {
        if rendersInProcess {
            // `.id(fileURL)` per CustomSidebarView's contract: its @State
            // model is keyed to the file it was created with, so switching
            // providers must rebuild it against the new file.
            CustomSidebarView(
                fileURL: fileURL,
                dataContext: dataContext,
                dispatch: dispatch,
                contentInsets: contentInsets
            )
            .id(fileURL)
        } else {
            // No `.id(fileURL)` here: the worker swaps files in place on the
            // next scene message, so remounting the surface would only flash
            // the previous sidebar's pixels during the switch.
            RemoteCustomSidebarHost(
                fileURL: fileURL,
                dataContext: dataContext,
                dispatch: dispatch,
                contentInsets: contentInsets,
                client: $client
            )
        }
    }
}
