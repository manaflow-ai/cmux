#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

private enum ComputerVisibilityRowItem: Identifiable {
    case visible(MacComputerSnapshot)
    case hidden(MobileHiddenComputer)

    var id: String {
        switch self {
        case .visible(let computer): computer.id
        case .hidden(let computer): computer.id
        }
    }

    var name: String {
        switch self {
        case .visible(let computer): computer.title
        case .hidden(let computer): computer.displayName
        }
    }

    var isVisible: Bool {
        if case .visible = self { return true }
        return false
    }

    var visibleComputer: MacComputerSnapshot? {
        guard case .visible(let computer) = self else { return nil }
        return computer
    }

    var hiddenComputer: MobileHiddenComputer? {
        guard case .hidden(let computer) = self else { return nil }
        return computer
    }
}

/// Insertion/removal phase for a row copy crossing sections: a transitioning
/// copy is invisible AND untouchable until the phase ends. SwiftUI still hit
/// tests zero-opacity views, so a bare opacity transition would leave an
/// invisible, enabled switch tappable during the sequenced fade-in delay.
private struct ComputerRowTransitionPhase: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
    }
}

/// A stable computer row whose trailing visibility switch survives transitions
/// between visible and hidden content.
///
/// Keeping one row identity and one `Toggle` instance lets SwiftUI carry the
/// native switch transaction through the model update.
private struct ComputerVisibilityRow: View {
    let item: ComputerVisibilityRowItem
    let setVisible: (Bool) -> Void
    let isVisibilityMutating: Bool
    var style: MacComputerRow.Style
    let connect: @MainActor (MacComputerSnapshot) -> Void
    let isConnecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isBusy: Bool { isVisibilityMutating }

    var body: some View {
        HStack(spacing: item.isVisible ? 8 : 12) {
            leadingContent
            ComputerVisibilityToggle(
                computerID: item.id,
                computerName: item.name,
                isVisible: item.isVisible,
                isDisabled: isBusy,
                setVisible: setVisible
            )
        }
        .padding(.vertical, item.isVisible ? 0 : 4)
        // A toggle that moves a row across sections (Computers screen) is a
        // remove+insert of two row copies: identity carries a Toggle through a
        // model update only within one ForEach. Sequencing the fades (outgoing
        // copy gone before the incoming copy appears) keeps the two switches
        // from blending into one malformed half-on ghost. Within a single
        // ForEach (disconnected shell) toggles reorder in place, so this
        // transition never fires there. Reduce Motion swaps rows instantly,
        // matching the owning lists' nil animation.
        .transition(reduceMotion ? .identity : .asymmetric(
            insertion: AnyTransition.modifier(
                active: ComputerRowTransitionPhase(shown: false),
                identity: ComputerRowTransitionPhase(shown: true)
            ).animation(.easeIn(duration: 0.15).delay(0.25)),
            removal: AnyTransition.modifier(
                active: ComputerRowTransitionPhase(shown: false),
                identity: ComputerRowTransitionPhase(shown: true)
            ).animation(.easeOut(duration: 0.12))
        ))
    }

    @ViewBuilder
    private var leadingContent: some View {
        if let computer = item.visibleComputer {
            MacComputerRow(
                computer: computer,
                style: style,
                connect: { _ in connect(computer) },
                isConnecting: isConnecting
            )
        } else if let computer = item.hiddenComputer {
            hiddenLabel(computer)
        }
    }

    private func hiddenLabel(_ computer: MobileHiddenComputer) -> some View {
        HStack(spacing: 12) {
            hiddenAvatar(computer)
            HStack(spacing: 6) {
                Text(computer.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if computer.instanceTag != nil,
                   let buildLabel = MacBuildChannel().label(
                       bundleID: nil,
                       tag: computer.instanceTag
                   ) {
                    ComputerBuildBadge(label: buildLabel)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private func hiddenAvatar(_ computer: MobileHiddenComputer) -> some View {
        ZStack {
            Circle()
                .fill(MachineAvatarColors.gradient(
                    customColor: computer.customColor,
                    fallbackIndex: nil,
                    machineID: computer.macDeviceID,
                    fallbackID: computer.id
                ))
                .frame(width: 36, height: 36)
            switch MacAvatarIcon.resolve(
                custom: computer.customIcon,
                defaultSymbol: "desktopcomputer"
            ) {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            case .emoji(let emoji):
                Text(emoji).font(.system(size: 18))
            }
        }
        .accessibilityHidden(true)
    }

    /// Red like a destructive swipe action, but deliberately WITHOUT
    /// `role: .destructive`: a destructive-role swipe button makes SwiftUI
    /// batch-delete the row on tap, and this tap only presents the
    /// confirmation dialog, so the unchanged model count aborted in
    /// UIKit's item-count assertion (TestFlight crash, build
    /// 20260731052644). Same pattern as `WorkspaceNavigationRow`'s
    /// confirm-first Delete.
}

/// Shared row wiring for visible and hidden computers in one stable `ForEach`.
struct ComputerVisibilityRows: View {
    let visibleComputers: [MacComputerSnapshot]
    let hiddenComputers: [MobileHiddenComputer]
    var style: MacComputerRow.Style = .computers
    var connect: @MainActor (MacComputerSnapshot) -> Void = { _ in }
    var connectingComputerID: String?
    var mutatingComputerIDs: Set<String> = []
    let hide: @MainActor (MacComputerSnapshot) -> Void
    let unhide: @MainActor (MobileHiddenComputer) -> Void

    private var items: [ComputerVisibilityRowItem] {
        visibleComputers.map(ComputerVisibilityRowItem.visible)
            + hiddenComputers.map(ComputerVisibilityRowItem.hidden)
    }

    var body: some View {
        ForEach(items) { item in
            ComputerVisibilityRow(
                item: item,
                setVisible: { visible in setVisibility(visible, for: item) },
                isVisibilityMutating: mutatingComputerIDs.contains(item.id),
                style: style,
                connect: connect,
                isConnecting: connectingComputerID == item.id,
            )
        }
    }

    private func setVisibility(_ visible: Bool, for item: ComputerVisibilityRowItem) {
        switch item {
        case .visible(let computer):
            guard !visible else { return }
            hide(computer)
        case .hidden(let computer):
            guard visible else { return }
            unhide(computer)
        }
    }

}
#endif
