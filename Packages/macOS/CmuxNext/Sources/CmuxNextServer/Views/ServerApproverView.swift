import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The Add Server card (palette "Add Server…", Settings > Machines, a pairing link): enter the
/// code, check the server's facts and four words, pick the team and name, Approve or Deny. One
/// layout per ``AddServerStep``; every button shows and binds its key, and the click and the key
/// run the same ``ServerModel/perform(_:)``.
struct ServerApproverView: View {
    let model: ServerModel
    let close: () -> Void
    var resized: (CGSize) -> Void = { _ in }
    @Environment(\.serverColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let step = model.addServerStep
        VStack(alignment: .leading, spacing: Metrics.space5) {
            if case let .added(name) = step {
                AddedServerBlock(name: name)
            } else {
                header
                codeField(step)
                if let candidate = Self.candidate(step) {
                    Group {
                        CandidateFacts(candidate: candidate)
                        words(candidate)
                        options(candidate)
                    }
                    .disabled(Self.isBusy(step))
                }
                if case let .approveFailed(_, reject) = step {
                    ServerErrorBanner(text: reject)
                }
            }
            footer(step)
        }
        .padding(Metrics.space6)
        .frame(width: ServerMetrics.cardWidth, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.overlays.animation(.crossfade), value: Self.layoutKey(step))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(ServerStrings.addServer).font(Font(Typography.system(size: TypeScale.title, weight: TypeScale.emphasis)))
                .foregroundStyle(colors.primary)
            Text(ServerStrings.enterServerCode).font(Font(Typography.body)).foregroundStyle(colors.secondary)
        }
    }

    private func codeField(_ step: AddServerStep) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            ServerTextField(text: model.approval.code, placeholder: Self.codePlaceholder, monospaced: true,
                            size: TypeScale.heading, alignment: .center, autofocus: true) {
                model.setApprovalCode($0)
            }
            .frame(height: ServerMetrics.codeFieldHeight).padding(.horizontal, Metrics.space4)
            .card(radius: ServerMetrics.fieldRadius)
            .overlay {
                if case .codeRefused = step {
                    RoundedRectangle(cornerRadius: ServerMetrics.fieldRadius, style: .continuous).strokeBorder(colors.critical, lineWidth: 1)
                }
            }
            .disabled(Self.isBusy(step))
            CodeStatusLine(step: step)
        }
    }

    private func words(_ candidate: PairingCandidate) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text(ServerStrings.wordsQuestion).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
            WordsGrid(words: candidate.words, size: TypeScale.field)
            Text(ServerStrings.wordsWarning).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func options(_ candidate: PairingCandidate) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            field(ServerStrings.name) {
                ServerTextField(text: model.approval.name, placeholder: candidate.name, monospaced: false, size: TypeScale.body) {
                    model.approval.name = $0
                }
                // On the field itself: a frame outside the card would widen nothing that draws.
                .frame(maxWidth: .infinity)
                .frame(height: ServerMetrics.rowFieldHeight).padding(.horizontal, Metrics.space3).card(radius: ServerMetrics.fieldRadius)
            }
            // One team needs no choice.
            if candidate.teams.count > 1 {
                field(ServerStrings.team) { TeamChips(model: model, teams: candidate.teams) }
            }
            Toggle(ServerStrings.runChief, isOn: Binding(get: { model.approval.runChief }, set: { model.approval.runChief = $0 }))
                .toggleStyle(.checkbox).font(Font(Typography.body)).foregroundStyle(colors.primary).tint(colors.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A caption over its control (labels of any length in any language, no column to align).
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(title).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
            content()
        }
    }

    /// Cancel and Deny stay pressable while an approve is in flight.
    private func footer(_ step: AddServerStep) -> some View {
        HStack(spacing: Metrics.space3) {
            if case .approving = step {
                ThemedSpinner(size: ServerMetrics.spinnerSize)
            }
            Spacer(minLength: 0)
            ForEach(model.addServerButtons, id: \.isDefault) { button in
                CmuxDialogActionButton(button.isDefault ? ServerStrings.returnTitle(step) : ServerStrings.escapeTitle(step),
                                       hint: button.isDefault ? .return : .escape) {
                    if model.perform(button.action) { close() }
                }
                .glassButtonStyle()
                .font(Font(button.isDefault ? Typography.bodyEmphasized : Typography.body))
                .disabled(!button.enabled)
            }
        }
    }

    /// The code's shape, not words: the same in every language.
    static let codePlaceholder = "XXXX-XXXX"

    static func candidate(_ step: AddServerStep) -> PairingCandidate? {
        switch step {
        case let .review(candidate), let .approving(candidate), let .approveFailed(candidate, _): candidate
        case .enterCode, .lookingUp, .codeRefused, .added: nil
        }
    }

    private static func isBusy(_ step: AddServerStep) -> Bool {
        if case .approving = step { return true }
        return false
    }

    /// Which layout shows, so the card animates between layouts and not on every keystroke.
    private static func layoutKey(_ step: AddServerStep) -> Int {
        switch step {
        case .enterCode, .lookingUp, .codeRefused: 0
        case .review, .approving: 1
        case .approveFailed: 2
        case .added: 3
        }
    }
}

/// Everything the pending pairing knows about the server.
struct CandidateFacts: View {
    let candidate: PairingCandidate
    @Environment(\.serverColors) private var colors

    var body: some View {
        HStack(spacing: Metrics.space3) {
            Icon(.machineRemote, size: ServerMetrics.factsIconSize).foregroundStyle(colors.secondary).frame(width: ServerMetrics.factsIconWidth)
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(verbatim: candidate.name).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
                Text(verbatim: facts).font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.space3).card()
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
        HStack(spacing: Metrics.space2) {
            ForEach(teams) { team in
                let selected = model.approval.team == team.id
                Button { model.approval.team = team.id } label: {
                    Text(verbatim: team.name).font(Font(selected ? Typography.bodyEmphasized : Typography.body))
                        .foregroundStyle(selected ? colors.primary : colors.secondary)
                        .padding(.horizontal, Metrics.space3).frame(height: ServerMetrics.chipHeight)
                        .background(Capsule().fill(selected ? colors.selection : colors.fill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
