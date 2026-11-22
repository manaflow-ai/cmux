import AppKit
import SwiftUI

struct AgentActivityEventList: View {
    let model: AgentActivityModel

    var body: some View {
        let current = model.currentEvent?.seq
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.selectedEvents.reversed()) { event in
                        AgentActivityEventRow(event: event, selected: event.seq == current)
                            .id(event.seq)
                            .contentShape(Rectangle())
                            .onTapGesture { model.scrub(to: event.seq) }
                    }
                }
            }
            .onChange(of: current) { _, seq in
                if let seq { reader.scrollTo(seq, anchor: .center) }
            }
        }
    }
}

struct AgentActivityEventRow: View {
    @Environment(\.agentActivityColors) private var colors
    let event: AgentActivityEvent
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(AgentActivityFormat.time(event.time))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(colors.tertiary)
                .lineLimit(1).fixedSize()
                .frame(width: 76, alignment: .leading)
            Image(systemName: AgentActivityFormat.symbol(event))
                .foregroundStyle(event.ok ? colors.secondary : colors.danger)
                .frame(width: 14)
            Text(event.tool ?? event.kind.rawValue).font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1).fixedSize()
            if let length = event.redactedTextLength {
                AgentActivityBadge(text: "\(AgentActivityStrings.typedTextHidden) · \(length)")
            }
            Text(event.target ?? "").font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(colors.secondary)
            Spacer(minLength: 6)
            if let code = event.errorCode {
                Text(code).font(.system(size: 10, design: .monospaced)).foregroundStyle(colors.danger)
            }
            if let ms = event.durationMs {
                Text("\(ms) ms").font(.system(size: 10).monospacedDigit()).foregroundStyle(colors.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(selected ? colors.selection : .clear)
    }
}
