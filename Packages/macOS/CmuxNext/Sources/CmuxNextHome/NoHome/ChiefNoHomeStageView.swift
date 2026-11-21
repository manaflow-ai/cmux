#if DEBUG
import SwiftUI

/// DEBUG ONLY: a workspace on the stage in the no-Home prototype: its tab bar (the terminal and the agent chats that
/// work there) and the terminal.
struct ChiefNoHomeStageView: View {
    let workspace: ChiefNoHomeWorkspace
    let threads: [ChiefNoHomeThread]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tab("terminal", workspace.branch, on: true)
                ForEach(threads) { tab($0.kind == .subagent ? "sparkles" : "bubble.left", $0.title, on: false) }
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(workspace.lines, id: \.self) { // visible-only: a fixed fixture of at most five lines
                    Text($0).font(.noHomeCode)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func tab(_ symbol: String, _ title: String, on: Bool) -> some View {
        Label(title, systemImage: symbol).font(.noHomeCaption).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(nsColor: .controlBackgroundColor) : .clear))
    }
}
#endif
