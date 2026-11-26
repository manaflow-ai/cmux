import SwiftUI

extension EnvironmentValues {
    /// The rows are drawn as a still (a tab card's picture, `AgentCardRasterizer`, or the live
    /// preview that stands in until it is drawn). `ImageRenderer` draws only SwiftUI's own views:
    /// a control UIKit draws (`Menu`, `ShareLink`, a text field) comes out as its yellow "can't
    /// render" placeholder (Leo, 2026-11-17: "Weird placeholder for retries esp in preview", the
    /// error card's Retry with another model). A row reads this and draws that control's label
    /// as plain SwiftUI instead, at the same size, so the still looks like the live chat.
    /// Declared here, below the chat, so the text the rows share (`SelectableText` in
    /// CmuxMobileMarkdown, a UIKit label since #52600) reads it too.
    @Entry public var chatStill = false
}
