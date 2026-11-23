import CmuxNextDesign
import Foundation

/// The Add Machine card's spec for each phase: pick (the host field, Name, the tailnet's machines), running (the steps
/// filling in), ready, failed (the steps, the failed one with its fix). Every spec has words and a way out.
enum AddMachineCardSpec {
    enum ID {
        static let destination = "destination", name = "name", candidate = "candidate"
        static let add = "add", tryAgain = "tryAgain", changeHost = "changeHost", fix = "fix", openWorkspace = "openWorkspace"
        static let copyDetails = "copyDetails", done = "done", cancel = "cancel"
    }

    @MainActor
    static func spec(runs: AddMachineRuns, candidates: AddMachineDialog.Candidates, values: [String: CmuxDialogValue],
                     variant: Variant = .lean) -> CmuxDialogSpec {
        let mode = runs.request.mode
        let adding = mode == .add
        func card(_ title: String, _ help: String? = nil, _ fields: [CmuxDialogField] = [], _ buttons: [CmuxDialogButton]) -> CmuxDialogSpec {
            CmuxDialogSpec(usesTransientMaterial: true, title: title, fields: fields, buttons: buttons,
                           identifier: "cmux.addMachine.card", showsAppIcon: false, help: help)
        }
        guard let run = runs.run else {
            return pick(candidates: candidates, values: values, variant: variant)
        }
        let checklist = AddMachineChecklist(events: run.events)
        let steps = Self.steps(checklist)
        let cancel = CmuxDialogButton(id: ID.cancel, title: AddMachineStrings.cancel, role: .cancel)
        let done = { (role: CmuxDialogButton.Role) in CmuxDialogButton(id: ID.done, title: AddMachineStrings.done, role: role) }
        let copy = CmuxDialogButton(id: ID.copyDetails, title: AddMachineStrings.copyDetails)
        switch run.outcome {
        case .running:
            let title = adding ? AddMachineStrings.addingTitle(run.name) : AddMachineStrings.checkingTitle(run.name)
            var buttons = [cancel]
            if adding { buttons.append(CmuxDialogButton(id: ID.add, title: AddMachineStrings.adding, role: .default, isEnabled: false)) }
            if case .check = mode { buttons.append(CmuxDialogButton(id: ID.fix, title: AddMachineStrings.checking, role: .default, isEnabled: false)) }
            return card(title, nil, [.steps(steps)], buttons)
        case .ready:
            let buttons = adding
                ? [done(.cancel), CmuxDialogButton(id: ID.openWorkspace, title: AddMachineStrings.openWorkspace, role: .default,
                                                   isEnabled: run.machineID != nil)]
                : [done(.default)]
            return card(AddMachineStrings.ready(run.name), adding ? AddMachineStrings.readyDetail : nil, [.steps(steps)], buttons)
        case .failed:
            let title = adding ? AddMachineStrings.addFailed(run.name) : AddMachineStrings.checkFailed(run.name)
            let buttons: [CmuxDialogButton] = switch mode {
            case .add: [copy, CmuxDialogButton(id: ID.changeHost, title: AddMachineStrings.changeHost),
                        CmuxDialogButton(id: ID.tryAgain, title: AddMachineStrings.tryAgain, role: .default)]
            case .check: [copy, CmuxDialogButton(id: ID.fix, title: AddMachineStrings.fix, role: .default)]
            case .checkJoined: [copy, done(.default)]
            }
            return card(title, nil, [.steps(steps)], buttons)
        }
    }

    /// How the pick card is laid out. `lean` ships (Leo, 2026-11-23: "get more creative with these lifeless-ass ... menus"); the
    /// others are the gallery's alternatives (AAAddMachineGalleryTests), `before` the card as it was.
    enum Variant: String, CaseIterable, Sendable {
        /// The card as it shipped: the app icon's empty column, a subtitle, a captioned Name and a captioned tailnet list.
        case before
        /// No icon, no printed explanation (an info circle with a hover has it), no captions: the host, the optional name,
        /// the tailnet's machines to pick from.
        case lean
        /// The tailnet's machines first (most people pick), the host to type under it, the name left to the host.
        case pickFirst
        /// One field and the tailnet list: the smallest card.
        case minimal
    }

    /// The pick phase's card: the host field, then what is on the tailnet.
    @MainActor
    static func pick(candidates: AddMachineDialog.Candidates, values: [String: CmuxDialogValue], variant: Variant) -> CmuxDialogSpec {
        let destination = values[ID.destination]?.text ?? ""
        let lean = variant != .before
        let host = CmuxDialogField.text(id: ID.destination, label: nil, initial: destination, placeholder: AddMachineStrings.hostPlaceholder, secure: false)
        let name = CmuxDialogField.text(id: ID.name, label: lean ? nil : AddMachineStrings.name, initial: values[ID.name]?.text ?? "",
                                        placeholder: lean ? AddMachineStrings.namePlaceholder : nil, secure: false)
        var tailnet: [CmuxDialogField] = []
        switch candidates {
        case .loading: tailnet.append(.progress(AddMachineStrings.lookingForPeers))
        case let .loaded(list) where !list.isEmpty:
            let picked = list.first { $0.destination == destination }
            let options = [CmuxDialogOption(label: lean ? AddMachineStrings.pickFromTailnet : "—", value: "")] + list.map {
                CmuxDialogOption(label: [$0.name, $0.os, badge($0) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), value: $0.id,
                                 isEnabled: $0.isPickable)
            }
            tailnet.append(.choice(id: ID.candidate, label: lean ? nil : AddMachineStrings.tailnet, options: options, selected: picked?.id ?? ""))
        default: break
        }
        let fields: [CmuxDialogField] = switch variant {
        case .before: [host, name] + tailnet
        case .lean: [host, name] + tailnet
        case .pickFirst: tailnet + [host]
        case .minimal: [host] + tailnet
        }
        let buttons = [
            CmuxDialogButton(id: ID.cancel, title: AddMachineStrings.cancel, role: .cancel),
            // Return always reaches Add; the card dims it while the field holds no host ssh takes, and Add does nothing then.
            CmuxDialogButton(id: ID.add, title: AddMachineStrings.add, role: .default),
        ]
        return CmuxDialogSpec(usesTransientMaterial: true, title: AddMachineStrings.title, fields: fields, buttons: buttons,
                              identifier: "cmux.addMachine.card", showsAppIcon: variant == .before, help: lean ? AddMachineStrings.subtitle : nil)
    }

    /// The checklist's rows as the card lists them: a fix shows on a failed or warned step; a step that failed with no
    /// words says cmux-tui stopped; the install row says when the app installs its own build.
    static func steps(_ checklist: AddMachineChecklist) -> [CmuxDialogStep] {
        checklist.rows.map { row in
            let state: CmuxDialogStep.State
            var detail = row.detail
            switch row.status {
            case .pending: state = .pending
            case .running:
                state = .running
                if row.step == .install, checklist.installing { detail = AddMachineStrings.installingAppBuild }
            case .done(.ok), .done(.fixed): state = .done
            case .done(.warn): state = .warning
            case .done(.fail):
                state = .failed
                if detail.isEmpty { detail = AddMachineStrings.stopped }
            case .done(.skip): state = .skipped
            }
            let showsFix = state == .failed || state == .warning
            return CmuxDialogStep(title: AddMachineStrings.step(row.step), state: state, detail: detail, fix: showsFix ? row.fix : nil)
        }
    }

    /// Why a machine cannot be picked, in the order a person would fix it, or that it is an agent peer.
    static func badge(_ candidate: HostCandidate) -> String? {
        if candidate.inApp { return AddMachineStrings.added }
        if !candidate.online { return AddMachineStrings.offline }
        if candidate.alreadyPeer { return AddMachineStrings.agentPeer }
        if candidate.sshOK == false { return AddMachineStrings.sshOff }
        return nil
    }
}
