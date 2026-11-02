#if os(iOS)
import SwiftUI

/// Find in Chat's bar over the top of the transcript: the query, "N of M", previous and
/// next, and Done. Return goes to the next match, as the Mac's find bar.
struct AgentChatFindBar: View {
    @Bindable var find: AgentChatFind
    let surface: AgentChatSurface
    let store: AgentChatStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in chat", text: $find.query)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    find.next()
                    focused = true
                }
                .accessibilityIdentifier("agentChat.find.field")
            Text(find.countText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("agentChat.find.count")
            Button {
                find.previous()
            } label: {
                Image(systemName: "chevron.up").frame(width: 32, height: 44).contentShape(.rect)
            }
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("agentChat.find.previous")
            Button {
                find.next()
            } label: {
                Image(systemName: "chevron.down").frame(width: 32, height: 44).contentShape(.rect)
            }
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("agentChat.find.next")
            Button("Done") { surface.closeFind() }
                .fontWeight(.semibold)
                .accessibilityIdentifier("agentChat.find.done")
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .onAppear { focused = surface.findFieldFocused }
        .onChange(of: surface.findFieldFocused) { _, wanted in if wanted != focused { focused = wanted } }
        .onChange(of: focused) { _, now in surface.findFieldFocused = now }
        .onChange(of: find.query) { find.search(store.turns) }
        .onChange(of: find.step) { surface.revealFindMatch() }
        // Output that arrives while the bar is up is searched too, streamed text included (a
        // chunk grows the last message in place); the current match stays.
        .onChange(of: AgentChatFind.revision(of: store.turns)) { if !find.query.isEmpty { find.refresh(store.turns) } }
    }
}

#endif
