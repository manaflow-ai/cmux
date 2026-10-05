import AppKit
import SwiftUI

/// The short guide the Coderouter header's "?" opens: what CodeRouter does
/// and how the section's rows work.
struct CoderouterGuideView: View {
    /// The one-line pitch: the "?" tooltip and the guide's first paragraph.
    static let summary = String(
        localized: "coderouter.guide.summary",
        defaultValue: "Add the Codex, Claude and OpenCode Go accounts you already have, and agents on your Cloud machines use them right away."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "coderouter.guide.title", defaultValue: "CodeRouter"))
                .cmuxFont(size: 13, weight: .semibold)
            paragraph(Self.summary)
            heading(String(localized: "coderouter.guide.sidebar.title", defaultValue: "In this sidebar"))
            paragraph(String(
                localized: "coderouter.guide.sidebar",
                defaultValue: "Click New Codex, Claude or OpenCode Go Account and sign in in the terminal that opens. Each account shows how much of its limit is left; hover it and click × to remove it. When one account reaches its limit, sessions move to another."
            ))
            heading(String(localized: "coderouter.guide.cli.title", defaultValue: "From a terminal"))
            command("cr add codex", String(localized: "coderouter.guide.cli.add", defaultValue: "Add an account. Also claude or opencode."))
            command("cr", String(localized: "coderouter.guide.cli.list", defaultValue: "List every account and its usage."))
            command("cr codex", String(localized: "coderouter.guide.cli.run", defaultValue: "Run Codex through CodeRouter on this Mac."))
            paragraph(String(
                localized: "coderouter.guide.team",
                defaultValue: "Accounts belong to the team selected at the top of this panel."
            ))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A command and what it does. Commands are literal and never localized.
    private func command(_ command: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Text(text)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// Opens the guide beside a header row. Anchored to the row's cell, not its
    /// hover button, so it stays open when the pointer leaves the row.
    func showCoderouterGuide(nodeID: String) {
        guard let outlineView,
              let row = (0..<outlineView.numberOfRows).first(where: { (outlineView.item(atRow: $0) as? CloudTreeNode)?.id == nodeID }),
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        guidePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: CoderouterGuideView())
        // The Cloud panel is the window's trailing sidebar, so open toward the content.
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .minX)
        guidePopover = popover
    }
}
