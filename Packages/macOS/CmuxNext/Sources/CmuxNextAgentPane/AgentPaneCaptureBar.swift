public import AppKit
public import CoreGraphics
import CmuxNextSettings

/// Capture… (`capture.open`, plans/cmux-next/capture-bar-DESIGN.md): opens or closes the capture bar
/// on a chat's composer, and keeps what its Pane shot captures. A second press while the bar
/// records stops the recording; the page decides that (`window.cmuxAcpmuxBridge.captureBar`).
/// Not an AgentPaneView extension: that type is at its size limit.
@MainActor public struct AgentPaneCaptureBar {
    private let pane: (@MainActor () async -> CGImage?)?

    /// `pane` captures the pane focused at the press (the chat's own pane when that is it).
    public init(pane: (@MainActor () async -> CGImage?)?) {
        self.pane = pane
    }

    /// Remembers this press's pane and toggles `view`'s bar (event `captureBar`, `{toggle: true}`).
    public func toggle(on view: AgentPaneView) {
        AgentPaneRecorder.shared.pressed(view, paneImage: pane)
        let value: JSONValue = ["toggle": .bool(true)]
        view.deliver([AgentPageEvent(kind: "captureBar", value: value)],
                     scripts: ["window.cmuxAcpmuxBridge?.captureBar?.(\(value.compactText));"])
    }

    /// The quit, after the chats' composers are saved (a slow stream stop never holds them up): a
    /// recording still running, or one not collected, is finished and kept, since no page collects
    /// it any more, unless its chat is incognito (``AgentPaneRecorder/finishForQuit()``).
    public static func finishForQuit() async {
        await AgentPaneRecorder.shared.finishForQuit()
    }

    /// The chat `window` shows when the focused pane is no chat: of the agent chats on screen in
    /// it, the largest. Walks only views on screen (a hidden subtree is skipped, and a chat's own
    /// subviews are not entered), so its cost follows what the window shows, not how many chats
    /// are open.
    public static func visibleChat(in window: NSWindow?) -> AgentPaneView? {
        guard let root = window?.contentView else { return nil }
        var best: (view: AgentPaneView, area: CGFloat)?
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            guard !view.isHidden else { continue }
            if let chat = view as? AgentPaneView {
                let area = chat.visibleRect.width * chat.visibleRect.height
                if area > 0, area > best?.area ?? 0 { best = (chat, area) }
                continue
            }
            pending.append(contentsOf: view.subviews)
        }
        return best?.view
    }
}
