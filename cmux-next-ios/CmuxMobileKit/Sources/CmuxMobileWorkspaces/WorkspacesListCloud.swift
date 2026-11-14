#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A Cloud machine's line on the Workspaces list, among the Macs' lines: what its state means
/// and the one thing to do about it. Paused: **Start** (its rows, if any, unfold in place).
/// Starting or being set up: "Waking up…" (or "Starting <name>…" for one New Cloud Workspace
/// made). Failed: its note and **Retry**. Running with no workspaces: **New Workspace**.
extension WorkspacesList {
    /// New Cloud Workspace: the pending machine line shows at once; its workspace opens when
    /// the machine runs and its daemon answers.
    func newCloudWorkspace() {
        guard let cloud = creator.cloud, cloud.canCreateMachine else {
            theme.haptics.warning()
            return
        }
        theme.haptics.impactLight()
        let open = open
        cloud.newCloudWorkspace { open($0) }
    }

    /// What the line says after the machine's name, and its glyph.
    static func cloudFoldText(_ fold: WorkspaceInbox.Fold) -> (detail: String, symbol: String) {
        let state = fold.mac.cloud
        switch fold.reason {
        case .cloudPaused:
            return (state?.status == .pausing ? "Pausing…" : "Paused", "pause.circle")
        case .cloudWaking:
            return ("Waking up…", "cloud")
        case .cloudFailed(let note):
            return (note ?? "Couldn't start", "exclamationmark.triangle")
        case .cloudEmpty:
            return ("No workspaces", "cloud")
        case .offline, .notConnected, .failed:
            return ("", "cloud")
        }
    }

    /// The whole line as one sentence ("Build box · Cloud · Paused"), for VoiceOver and tests.
    static func cloudFoldSentence(_ fold: WorkspaceInbox.Fold) -> String {
        if fold.reason == .cloudWaking, fold.mac.cloud?.pendingWorkspace == true { return "Starting \(fold.mac.name)…" }
        return "\(fold.mac.name) · Cloud · \(cloudFoldText(fold).detail)"
    }

    func cloudFoldLine(_ fold: WorkspaceInbox.Fold, isOpen: Bool) -> some View {
        let machine = fold.mac
        let (detail, symbol) = Self.cloudFoldText(fold)
        let pending = fold.reason == .cloudWaking && machine.cloud?.pendingWorkspace == true
        let foldable = !fold.workspaces.isEmpty && !fold.isForcedOpen
        return HStack(spacing: 0) {
            Button {
                guard foldable else { return }
                theme.haptics.selection()
                let opening = !unfolded.contains(machine.id)
                withAnimation(theme.motion.smooth.animation.unlessReduceMotion) {
                    if opening { unfolded.insert(machine.id) } else { unfolded.remove(machine.id) }
                }
                if opening { lookAtCloud?(machine.id) }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: symbol)
                        .frame(width: gutter)
                        .accessibilityHidden(true)
                    Text(pending ? "Starting \(machine.name)…" : "\(machine.name) · \(detail)")
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if foldable {
                        Text("\(fold.workspaces.count)").monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(theme.type.meta.weight(.semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .padding(.leading, 6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.cloudFoldSentence(fold)))
            .accessibilityValue(foldable ? (isOpen ? "Expanded" : "Collapsed") : "")
            // A tap unfolds its rows only when it has some: otherwise it is a label, not a button.
            .accessibilityAddTraits(foldable ? .isButton : [])
            .allowsHitTesting(foldable)
            .accessibilityIdentifier("workspaces.cloud.\(machine.id)")
            cloudFoldAction(fold)
                .padding(.leading, 10)
        }
        .font(theme.type.meta.weight(.semibold))
        .foregroundStyle(theme.colors.label2)
        .frame(minHeight: 32)
    }

    @ViewBuilder private func cloudFoldAction(_ fold: WorkspaceInbox.Fold) -> some View {
        let id = fold.mac.id
        switch fold.reason {
        case .cloudPaused:
            if let cloud = creator.cloud, fold.mac.cloud?.status == .paused {
                Button("Start") {
                    theme.haptics.impactLight()
                    cloud.start(machineID: id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.colors.accent.color)
                .accessibilityIdentifier("workspaces.cloud.start.\(id)")
            } else if fold.mac.cloud?.status == .pausing {
                CmuxSpinner().controlSize(.mini)
            }
        case .cloudWaking:
            CmuxSpinner().controlSize(.mini)
                .accessibilityIdentifier("workspaces.cloud.waking.\(id)")
        case .cloudFailed:
            if let cloud = creator.cloud {
                Button("Retry") {
                    theme.haptics.impactLight()
                    cloud.start(machineID: id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.colors.accent.color)
                .accessibilityIdentifier("workspaces.cloud.retry.\(id)")
            }
        case .cloudEmpty:
            if creator.availableMacs.contains(where: { $0.id == id }) {
                Button("New Workspace") { create(.terminal, directory: nil, on: id) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.colors.accent.color)
                    .accessibilityIdentifier("workspaces.cloud.new.\(id)")
            }
        case .offline, .notConnected, .failed:
            EmptyView()
        }
    }
}
#endif
