#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY: a thread's chat in the no-Home prototype: its header (avatar, name, status), the messages and the
/// message box. `switcher` puts the thread switcher in the header (the side panel variant).
struct ChiefNoHomeChatView: View {
    let thread: ChiefNoHomeThread
    let fixture: ChiefNoHomeFixture
    var switcher = false
    var narrow = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(fixture.messages.enumerated()), id: \.offset) { _, message in bubble(message.author, message.text) } // visible-only: a fixed fixture of four messages
                    if thread.kind == .chief { subagentChips }
                }
                .padding(narrow ? 14 : 24)
                .frame(maxWidth: narrow ? .infinity : 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ChiefNoHomeThreadRow(thread: thread, compact: true).fixedSize()
            if switcher {
                Menu {
                    ForEach(fixture.chats) { Text($0.title) }
                } label: { Label("Threads", systemImage: "chevron.down") }
                    .menuStyle(.button).buttonStyle(.cmuxPressFill).fixedSize()
            }
            Spacer()
            Text(thread.detail).font(.noHomeCaption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private func bubble(_ author: String, _ text: String) -> some View {
        let mine = author == "Lawrence"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Text(author).font(.noHomeCaptionEmphasis).foregroundStyle(.secondary)
            Text(text).font(.noHomeBody).padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(mine ? Color(nsColor: .controlAccentColor).opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var subagentChips: some View {
        HStack(spacing: 6) {
            ForEach(fixture.subagents) { agent in
                Label(String(agent.title.prefix(5)), systemImage: agent.status == .needsYou ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(.noHomeCaption).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private var composer: some View {
        HStack {
            Text("Message \(thread.title)").font(.noHomeBody).foregroundStyle(.tertiary)
            Spacer()
            Image(systemName: "arrow.up.circle.fill").font(.noHomeSend).foregroundStyle(Color(nsColor: .controlAccentColor))
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(narrow ? 10 : 16)
        .frame(maxWidth: narrow ? .infinity : 760)
    }
}
#endif
