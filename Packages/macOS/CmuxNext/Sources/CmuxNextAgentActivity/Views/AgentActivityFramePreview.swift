import AppKit
import SwiftUI

struct AgentActivityFramePreview: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        let event = model.currentFrameEvent
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(colors.elevated)
            if let event, let frame = event.displayFrame, !frame.expired {
                AgentActivityFrameImage(model: model, frame: frame)
                    .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            if let point = event.clickPoint {
                                AgentActivityClickMarker(hex: session.colorHex)
                                    .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: colors.shadow, radius: 8, y: 2)
                    .padding(12)
            } else {
                Text(event?.displayFrame?.expired == true ? AgentActivityStrings.frameExpired : AgentActivityStrings.noFrame)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.secondary)
            }
            if model.watching.contains(session.id) {
                VStack {
                    HStack {
                        Spacer()
                        AgentActivityBadge(text: AgentActivityStrings.live, tint: colors.danger)
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
    }
}

struct AgentActivityFilmstrip: View {
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        let current = model.currentEvent?.seq
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(model.selectedEvents.filter { $0.displayFrame != nil }) { event in
                        if let frame = event.displayFrame {
                            AgentActivityThumbnail(model: model, frame: frame, ok: event.ok,
                                                   selected: event.seq == current, hex: session.colorHex)
                                .id(event.seq)
                                .onTapGesture { model.scrub(to: event.seq) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .onChange(of: current) { _, seq in
                if let seq { reader.scrollTo(seq, anchor: .center) }
            }
        }
    }
}
