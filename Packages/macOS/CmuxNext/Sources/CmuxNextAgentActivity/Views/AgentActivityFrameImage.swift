import AppKit
import SwiftUI

/// Loads a frame's pixels through the model (the source decodes off main).
struct AgentActivityFrameImage: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let frame: AgentActivityFrameRef
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(colors.hover)
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium)
            }
        }
        .task(id: frame.blob) { image = await model.image(for: frame) }
    }
}

struct AgentActivityThumbnail: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let frame: AgentActivityFrameRef
    let ok: Bool
    let selected: Bool
    let hex: String

    var body: some View {
        AgentActivityFrameImage(model: model, frame: frame)
            .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? AgentActivityColor.color(hex: hex) : (ok ? colors.separator : colors.danger),
                            lineWidth: selected ? 2 : 1)
            )
            .opacity(frame.expired ? 0.35 : 1)
    }
}
