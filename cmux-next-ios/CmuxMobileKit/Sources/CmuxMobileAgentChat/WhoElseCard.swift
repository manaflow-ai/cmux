#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// "Who else is working on these files" (`WhoElseCall`) as one compact card in place of the raw
/// MCP or shell row, as the Mac draws it (`WhoElseCard.tsx`): a line saying how many other sessions
/// touch the files, then one row per session with its name as a chip that opens its chat, its
/// harness and branch, up to two pull requests, how long ago, and what it edited or read in common.
/// The first five rows show; "N more" opens the rest.
struct WhoElseCard: View {
    /// The tool call's id (the disclosure's key).
    let id: String
    let call: WhoElseCall
    /// Opens a session of this chat's Mac; nil: the chips are names only.
    var open: (@MainActor (WhoElseCall.Session) -> Void)?
    @State private var localOpen = false
    @Environment(\.chatDisclosures) private var disclosures
    @Environment(\.transcriptFoldHold) private var holdFold
    private let type = CmuxMobileTheme.standard.type

    static func disclosureKey(_ id: String) -> String { "who-else-\(id)" }

    /// Kept by the transcript when it has a store (its rows are reused cells), else here.
    private var expanded: Bool { disclosures?.isOpen(Self.disclosureKey(id)) ?? localOpen }

    var body: some View {
        let sessions = call.answer?.sessions ?? []
        let shown = expanded ? sessions : Array(sessions.prefix(WhoElseCall.rowsShown))
        let hidden = call.hiddenCount(shown: shown.count)
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(shown) { session in
                // A peer's session has no id this Mac can open.
                WhoElseRow(session: session, open: session.host == nil && !session.sessionId.isEmpty ? open : nil)
            }
            if hidden > 0, !expanded {
                Button {
                    toggleDisclosure(holdFold) {
                        if let disclosures { disclosures.set(Self.disclosureKey(id), true) } else { localOpen = true }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(WhoElseCall.more(hidden))
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .font(type.meta)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, 26)
                .padding(.vertical, -10)
                .accessibilityIdentifier("agentChat.whoElse.more")
            }
            if let note = call.unreachedNote {
                Text(note)
                    .font(type.meta)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentChat.whoElse")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(type.toolRow)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if call.pending {
                WorkingLabel(call.line, font: type.toolRow)
            } else {
                Text(call.line).font(type.toolRow.weight(.medium)).foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
        }
        .frame(minHeight: 32)
    }
}

/// One session: live dot, name chip, "harness · branch", pull requests and how long ago; under it
/// what it has in common with the files asked about.
private struct WhoElseRow: View {
    let session: WhoElseCall.Session
    let open: (@MainActor (WhoElseCall.Session) -> Void)?
    private let type = CmuxMobileTheme.standard.type

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.live ? Color.cmuxMobileSuccess : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                chip
                    .layoutPriority(1)
                let place = session.whereText
                if !place.isEmpty {
                    Text(place)
                        .font(type.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ForEach(Array(session.pullRequests.prefix(2)), id: \.self) { url in
                    if let link = URL(string: url) {
                        Link(WhoElseCall.pullLabel(url), destination: link)
                            .font(type.meta)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 4)
                Text(session.agoText)
                    .font(type.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            let what = session.whatText
            if !what.isEmpty {
                Text(what)
                    .font(type.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 13)
            }
        }
        .padding(.leading, 26)
    }

    @ViewBuilder private var chip: some View {
        let name = Text(session.displayName)
            .font(type.chip)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.cmuxMobileFill, in: .capsule)
        if let open {
            Button { open(session) } label: {
                name
                    .foregroundStyle(Color.cmuxMobileAccent)
                    // 44 pt target; the row keeps its own height.
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .accessibilityLabel(String(localized: "mobile.agentChat.whoElse.open", defaultValue: "Open \(session.displayName)", bundle: .module))
            .accessibilityIdentifier("agentChat.whoElse.open")
        } else {
            name.foregroundStyle(.primary)
        }
    }
}
#endif
