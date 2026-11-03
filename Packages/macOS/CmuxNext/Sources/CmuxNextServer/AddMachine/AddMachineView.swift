import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The Add Machine card (palette "Add Machine…", Settings > Machines, the Machines section, the
/// sidebar menu) and Check Machine: the host field with the tailnet's machines under it, then the
/// nine steps filling in live, then ready or failed. One layout per ``AddMachineModel/Phase``;
/// every button shows and binds its key, and the click and the key run the same
/// ``AddMachineModel/perform(_:)``.
struct AddMachineView: View {
    let model: AddMachineModel
    let close: () -> Void
    var resized: (CGSize) -> Void = { _ in }
    @Environment(\.serverColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = model.phase
        VStack(alignment: .leading, spacing: Metrics.space5) {
            header(phase)
            if phase == .pick {
                fields
                AddMachineCandidateList(model: model)
            } else {
                AddMachineChecklistView(model: model)
            }
            footer(phase)
        }
        .padding(Metrics.space6)
        .frame(width: ServerMetrics.cardWidth, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.overlays.animation(.crossfade), value: Self.layoutKey(phase))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
    }

    @ViewBuilder private func header(_ phase: AddMachineModel.Phase) -> some View {
        switch phase {
        case .pick:
            VStack(alignment: .leading, spacing: Metrics.space1) {
                titleText(AddMachineStrings.title)
                Text(AddMachineStrings.subtitle).font(Font(Typography.body)).foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .running:
            titleText(model.mode == .add ? AddMachineStrings.adding(model.runName) : AddMachineStrings.checking(model.runName))
        case .ready:
            HStack(spacing: Metrics.space3) {
                Icon(.statusSuccess, size: ServerMetrics.factsIconSize).foregroundStyle(colors.ok)
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    titleText(AddMachineStrings.ready(model.runName))
                    if model.mode == .add {
                        Text(AddMachineStrings.readyDetail).font(Font(Typography.body)).foregroundStyle(colors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .failed:
            HStack(spacing: Metrics.space3) {
                Icon(.statusWarning, size: ServerMetrics.factsIconSize).foregroundStyle(colors.critical)
                titleText(model.mode == .add ? AddMachineStrings.addFailed(model.runName) : AddMachineStrings.checkFailed(model.runName))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func titleText(_ text: String) -> some View {
        Text(text).font(Font(Typography.system(size: TypeScale.title, weight: TypeScale.emphasis))).foregroundStyle(colors.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            ServerTextField(text: model.destination, placeholder: AddMachineStrings.hostPlaceholder, monospaced: false,
                            size: TypeScale.field, autofocus: true) {
                model.destination = $0
            }
            .frame(maxWidth: .infinity)
            .frame(height: ServerMetrics.rowFieldHeight + Metrics.space4).padding(.horizontal, Metrics.space4)
            .card(radius: ServerMetrics.fieldRadius)
            .accessibilityLabel(Text(AddMachineStrings.hostPlaceholder))
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(AddMachineStrings.name).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                ServerTextField(text: model.name, placeholder: model.defaultName, monospaced: false, size: TypeScale.body) {
                    model.name = $0
                }
                .frame(maxWidth: .infinity)
                .frame(height: ServerMetrics.rowFieldHeight).padding(.horizontal, Metrics.space3).card(radius: ServerMetrics.fieldRadius)
                .accessibilityLabel(Text(AddMachineStrings.name))
            }
        }
    }

    private func footer(_ phase: AddMachineModel.Phase) -> some View {
        HStack(spacing: Metrics.space3) {
            if phase == .running {
                ThemedSpinner(size: ServerMetrics.spinnerSize)
            }
            Spacer(minLength: 0)
            ForEach(model.buttons, id: \.action) { button in
                CmuxDialogActionButton(AddMachineStrings.title(button.action, phase: phase), hint: Self.hint(button.key)) {
                    if model.perform(button.action) { close() }
                }
                .glassButtonStyle()
                .font(Font(button.key == .return ? Typography.bodyEmphasized : Typography.body))
                .disabled(!button.enabled)
            }
        }
    }

    private static func hint(_ key: AddMachineButton.Key?) -> CmuxDialogKeyHint? {
        switch key {
        case .return: .return
        case .escape: .escape
        case nil: nil
        }
    }

    /// Which layout shows, so the card animates between layouts and not on every keystroke or line.
    private static func layoutKey(_ phase: AddMachineModel.Phase) -> Int {
        switch phase {
        case .pick: 0
        case .running: 1
        case .ready: 2
        case .failed: 3
        }
    }
}

/// The tailnet's machines under the field: a spinner while `candidates --probe` runs, then one row
/// per peer. Peers that are already added, offline or have ssh off are greyed and say why. Without
/// Tailscale the list is not shown at all.
struct AddMachineCandidateList: View {
    let model: AddMachineModel
    @Environment(\.serverColors) private var colors

    var body: some View {
        switch model.candidates {
        case .loading:
            HStack(spacing: Metrics.space2) {
                ThemedSpinner(size: ServerMetrics.spinnerSize)
                Text(AddMachineStrings.lookingForPeers).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            }
        case let .loaded(list) where !list.isEmpty:
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(AddMachineStrings.tailnet).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { candidate in row(candidate) }
                    }
                    .thinScrollers()
                }
                .frame(maxHeight: AddMachineMetrics.candidateListHeight)
                .card(radius: ServerMetrics.fieldRadius)
            }
        case .loaded, .unavailable:
            EmptyView()
        }
    }

    private func row(_ candidate: HostCandidate) -> some View {
        let picked = model.destination == candidate.destination
        let badge = Self.badge(candidate)
        return Button { model.pick(candidate) } label: {
            HStack(spacing: Metrics.space3) {
                Icon(.machineRemote, size: Metrics.smallIconSize).foregroundStyle(colors.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: candidate.name).font(Font(Typography.body)).foregroundStyle(colors.primary).lineLimit(1)
                    if !candidate.os.isEmpty {
                        Text(verbatim: candidate.os).font(Font(Typography.caption)).foregroundStyle(colors.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: Metrics.space2)
                if let badge {
                    Text(badge).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                }
            }
            .padding(.horizontal, Metrics.space3).padding(.vertical, Metrics.space2)
            .background(picked ? colors.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!candidate.isPickable)
        .opacity(candidate.isPickable ? 1 : AddMachineMetrics.disabledOpacity)
        .accessibilityLabel(Text(verbatim: ([candidate.name, candidate.os] + (badge.map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// Why a peer cannot be picked, in the order a person would fix it, or that it is an agent peer
    /// the app does not have yet (pickable).
    static func badge(_ candidate: HostCandidate) -> String? {
        if candidate.inApp { return AddMachineStrings.candidateAdded }
        if !candidate.online { return AddMachineStrings.candidateOffline }
        if candidate.alreadyPeer { return AddMachineStrings.candidateAgentPeer }
        if candidate.sshOK == false { return AddMachineStrings.candidateSSHOff }
        return nil
    }
}

/// The steps of a run. While it goes well the card shows one progress line ("Step 3 of 9: Start the
/// daemon") with Show Details; a step that failed or warned opens the whole list, each step with its glyph,
/// its detail and, when it has one, its fix (user 2026-10-31, Chief msg 19277: "unintuitive to use").
/// The failed step stays open with its whole detail and fix; the others keep to one line.
struct AddMachineChecklistView: View {
    let model: AddMachineModel
    @Environment(\.serverColors) private var colors
    @State private var showsDetails = false

    var body: some View {
        let failing = model.checklist.failing?.step
        let open = showsDetails || model.checklist.needsPerson
        VStack(alignment: .leading, spacing: Metrics.space3) {
            if !model.checklist.needsPerson { progress(open: open) }
            if open {
                ForEach(model.checklist.rows) { row in
                    rowView(row, open: row.step == failing)
                }
            }
        }
        .padding(Metrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func progress(open: Bool) -> some View {
        let summary = model.checklist.summary
        return VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space3) {
                Text(AddMachineStrings.progress(summary)).font(Font(Typography.body)).foregroundStyle(colors.primary).lineLimit(1)
                Spacer(minLength: Metrics.space2)
                Button(open ? AddMachineStrings.hideDetails : AddMachineStrings.showDetails) { showsDetails.toggle() }
                    .buttonStyle(.plain).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
            }
            ProgressView(value: Double(summary.done), total: Double(max(summary.total, 1))).progressViewStyle(.linear)
        }
    }

    private func rowView(_ row: HostChecklist.Row, open: Bool) -> some View {
        let detail = detail(row)
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
            glyph(row.status).frame(width: AddMachineMetrics.glyphWidth)
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(AddMachineStrings.step(row.step)).font(Font(open ? Typography.bodyEmphasized : Typography.body))
                    .foregroundStyle(row.status == .pending ? colors.tertiary : colors.primary)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(Font(Typography.caption)).foregroundStyle(open ? colors.critical : colors.secondary)
                        .lineLimit(open ? nil : 1).fixedSize(horizontal: false, vertical: open)
                        .textSelection(.enabled)
                }
                if let fix = row.fix, open || row.status == .done(.warn) {
                    Text(verbatim: fix).font(Font(Typography.caption)).foregroundStyle(colors.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: ([AddMachineStrings.step(row.step), AddMachineStrings.status(row.status), detail] + (row.fix.map { [$0] } ?? []))
            .filter { !$0.isEmpty }.joined(separator: ". ")))
    }

    private func detail(_ row: HostChecklist.Row) -> String {
        if row.step == .install, row.status == .running, model.installingAppBuild { return AddMachineStrings.installingAppBuild }
        if row.status == .done(.fail), row.detail.isEmpty { return AddMachineStrings.stopped }
        return row.detail
    }

    @ViewBuilder private func glyph(_ status: HostChecklist.Status) -> some View {
        switch status {
        case .pending: Icon(.stateIdle, size: Metrics.smallIconSize).foregroundStyle(colors.tertiary)
        case .running: ThemedSpinner(size: ServerMetrics.spinnerSize)
        case .done(.ok): Icon(.statusComplete, size: Metrics.smallIconSize).foregroundStyle(colors.ok)
        case .done(.fixed): Icon(.statusSuccess, size: Metrics.smallIconSize).foregroundStyle(colors.ok)
        case .done(.warn): Icon(.statusWarning, size: Metrics.smallIconSize).foregroundStyle(colors.warning)
        case .done(.fail): Icon(.statusError, size: Metrics.smallIconSize).foregroundStyle(colors.critical)
        case .done(.skip): Icon(.stateOff, size: Metrics.smallIconSize).foregroundStyle(colors.tertiary)
        }
    }
}

/// Layout constants of the Add Machine card beyond the Add Server card's (`ServerMetrics`).
enum AddMachineMetrics {
    static let candidateListHeight: CGFloat = 168
    static let glyphWidth: CGFloat = 16
    static let disabledOpacity: CGFloat = 0.5
    /// The Machines section's status dot.
    static let dotSize: CGFloat = 6
}
