import AppKit
import CmuxNextDesign
import SwiftUI

/// The approving device's sheet (palette "Add Server…", the menubar, the
/// iPhone after a scan): enter the code, check the server's facts and four
/// words, pick the team and name, Approve. One sheet for every pairing style.
struct ServerApproverView: View {
    let model: ServerModel
    let close: () -> Void
    @Environment(\.serverColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ServerStrings.addServer).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.primary)
            ServerTextField(text: model.approval.code, placeholder: "XXXX-XXXX", monospaced: true, size: 18) {
                model.setApprovalCode($0)
            }
            .frame(height: 38).padding(.horizontal, 10).card(radius: 8)
            if let candidate = model.candidate {
                CandidateFacts(candidate: candidate)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ServerStrings.wordsMatch).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                    WordsGrid(words: candidate.words, size: 14)
                }
                field(ServerStrings.team) { TeamChips(model: model, teams: candidate.teams) }
                field(ServerStrings.name) {
                    ServerTextField(text: model.approval.name, placeholder: candidate.name, monospaced: false, size: 13) {
                        model.approval.name = $0
                    }
                    .frame(height: 28).padding(.horizontal, 8).card(radius: 7)
                }
            }
            if let reject = model.lastReject {
                Text(reject).font(.system(size: 11.5)).foregroundStyle(colors.critical)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: ServerStrings.cancel) {
                    model.cancelApproval()
                    close()
                }
                PillButton(title: ServerStrings.approve, prominent: true) { model.approve() }
                    .disabled(!model.canApprove)
            }
        }
        .padding(ServerMetrics.padding + 2)
        .frame(width: ServerMetrics.dashboardWidth)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.candidate)
        .onChange(of: model.lastApproved) { _, approved in
            if approved != nil { close() }
        }
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(colors.tertiary)
            content()
        }
    }
}

/// Everything the pending pairing knows about the server.
struct CandidateFacts: View {
    let candidate: PairingCandidate
    @Environment(\.serverColors) private var colors

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 18)).foregroundStyle(colors.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: candidate.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.primary)
                Text(verbatim: facts).font(.system(size: 11.5)).foregroundStyle(colors.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10).card()
    }

    private var facts: String {
        var parts = [candidate.os, candidate.version]
        if let region = candidate.region {
            parts.append(Locale.current.localizedString(forRegionCode: region) ?? region)
        }
        return parts.joined(separator: " · ")
    }
}

/// Team choice as chips (no system menu, so no accent highlight).
struct TeamChips: View {
    let model: ServerModel
    let teams: [ServerTeam]
    @Environment(\.serverColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            ForEach(teams) { team in
                let selected = model.approval.team == team.id
                Button { model.approval.team = team.id } label: {
                    Text(verbatim: team.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? colors.primary : colors.secondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(selected ? colors.selection : colors.fill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
