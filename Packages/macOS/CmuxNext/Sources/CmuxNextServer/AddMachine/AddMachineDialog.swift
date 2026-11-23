public import AppKit
import CmuxNextDesign

/// Add Machine and Check Machine for the app: the runs and their card. Made once and kept, so a run in flight
/// survives the card closing and a reopen shows it again.
@MainActor
public final class AddMachineCard {
    public let runs: AddMachineRuns
    /// The native card (tests).
    let dialog: AddMachineDialog

    public init(services: AddMachineServices) {
        runs = AddMachineRuns(services: services)
        dialog = AddMachineDialog(runs: runs)
    }

    /// Opens Add Machine over `window`. A destination (the CLI, MCP, a script) only fills the field: the add starts
    /// when the person presses Add. The card takes the keys for its field.
    public func open(destination: String? = nil, name: String? = nil, over window: NSWindow?) {
        runs.begin(destination: destination, name: name)
        dialog.open(over: window)
    }

    /// Opens Add Machine and starts the add at once: a person's own click elsewhere (Add Device's Any Computer way)
    /// already chose the host.
    public func add(destination: String, name: String?, over window: NSWindow?) {
        runs.begin(destination: destination, name: name)
        runs.add(destination: destination, name: name ?? "")
        dialog.open(over: window)
    }

    /// Opens Check Machine for an SSH machine the app has and runs doctor.
    public func check(host: String, machineID: String, over window: NSWindow?) {
        runs.beginCheck(host: host, machineID: machineID)
        dialog.open(over: window)
    }

    /// Opens Check for a machine that joined with a one-line token and runs `machine doctor ID`.
    public func checkJoined(id: String, name: String, rowID: String? = nil, over window: NSWindow?) {
        runs.beginJoinedCheck(id: id, name: name, rowID: rowID)
        dialog.open(over: window)
    }

    /// Nil once the run in flight ended ready, else why not.
    public func finished() async -> String? {
        await runs.finished()
    }
}

/// The Add Machine card (palette "Add Machine…", Settings > Machines, the Machines section, Add Device's Any Computer
/// way) and Check Machine: the one cmux dialog card, native from its first frame (Lawrence 2026-11-17: "most dialogs
/// should have 0 react involved"). The host field with the tailnet's machines under it, then the steps filling in
/// live, then ready or failed (plans/cmux-next/add-machine-DESIGN.md). Every button binds its key; Escape always
/// closes it, and a run keeps going when it closes.
@MainActor
final class AddMachineDialog {
    enum Candidates: Equatable { case loading, unavailable, loaded([HostCandidate]) }

    let runs: AddMachineRuns
    let panel = CmuxFloatingDialogPanel(identifier: "cmux.addMachine")
    private var isOpen = false
    /// The opening the fields were filled for (``AddMachineRuns/Request/seq``).
    private var seq: Int?
    private(set) var candidates = Candidates.unavailable
    private var candidatesRead = 0
    /// The agent peer last picked from the list (already enrolled, not in the app yet).
    private var picked: HostCandidate?
    /// The list's pick last put in the host field: a later edit of the field never puts it back.
    private var appliedPick: String?
    /// The pending close of a finished run (``closeWhenReady()``); stops when the card hides or draws another state.
    private var closeTask: Task<Void, Never>?
    /// How long the ready card shows before it goes by itself.
    static let readyHold = Duration.seconds(2)

    init(runs: AddMachineRuns) {
        self.runs = runs
        panel.takesKeyboardOnShow = true
        // A real window: it drags, Escape and a click outside close it, and a finished add closes itself.
        panel.hidesOnOutsideClick = true
        panel.onHide = { [weak self] in
            self?.isOpen = false
            self?.closeTask?.cancel()
        }
        runs.changed = { [weak self] in self?.draw() }
    }

    func open(over window: NSWindow?) {
        isOpen = true
        panel.anchor = { [weak window] in window }
        if runs.request.seq != seq { opened() }
        draw()
    }

    /// A new opening: the fields as the opener filled them, and the tailnet's machines read again for Add Machine.
    private func opened() {
        seq = runs.request.seq
        (picked, appliedPick) = (nil, nil)
        panel.hide()
        isOpen = true
        if runs.request.mode == .add, runs.run == nil { loadCandidates() } else { candidates = .unavailable }
    }

    func draw() {
        guard isOpen else { return }
        let values = panel.dialogView.flatMap { $0.dialog.values.isEmpty ? nil : $0.dialog.values } ?? initialValues()
        let spec = AddMachineCardSpec.spec(runs: runs, candidates: candidates, values: values)
        guard panel.dialogView?.spec != spec || !panel.isVisible else { return }
        let card = panel.show(spec) { [weak self] id in self?.pressed(id) }
        card.dialog.onEdit = { [weak self, weak card] values in
            guard let self, let card else { return }
            self.edited(values, in: card)
        }
        edited(card.dialog.values, in: card)
        closeWhenReady()
    }

    /// A finished run closes its card after a short hold (the person saw it work; Open Workspace and Done are still
    /// there until then), never one still running or failed.
    private func closeWhenReady() {
        guard runs.run?.outcome == .ready else {
            closeTask?.cancel()
            return
        }
        guard closeTask == nil || closeTask?.isCancelled == true else { return }
        // task-owner: one close per ready card; hiding or any other state cancels it.
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.readyHold)
            guard !Task.isCancelled, let self, runs.run?.outcome == .ready else { return }
            closeTask = nil
            panel.hide()
        }
    }

    private func initialValues() -> [String: CmuxDialogValue] {
        let run = runs.request.mode == .add ? runs.run : nil
        let destination = run?.destination ?? runs.request.destination ?? ""
        let name = run?.destination != nil ? run?.name ?? "" : runs.request.name ?? ""
        return [AddMachineCardSpec.ID.destination: .text(destination), AddMachineCardSpec.ID.name: .text(name)]
    }

    /// The person typed or picked: a picked machine fills the host field, and Add works once ssh takes the host.
    private func edited(_ values: [String: CmuxDialogValue], in card: CmuxDialogView) {
        if let id = values[AddMachineCardSpec.ID.candidate]?.text, id != appliedPick, case let .loaded(list) = candidates,
           let candidate = list.first(where: { $0.id == id }), candidate.isPickable {
            appliedPick = id
            picked = candidate.alreadyPeer ? candidate : nil
            card.dialog.setValue(.text(candidate.destination), for: AddMachineCardSpec.ID.destination)
        }
        let destination = card.dialog.values[AddMachineCardSpec.ID.destination]?.text ?? ""
        card.buttonView(AddMachineCardSpec.ID.add)?.isEnabled = runs.parse(destination) != nil
    }

    private func pressed(_ id: String) {
        let values = panel.dialogView?.dialog.values ?? [:]
        typealias ID = AddMachineCardSpec.ID
        switch id {
        case ID.add: add(values)
        case ID.tryAgain:
            guard let run = runs.run, let destination = run.destination else { return add(values) }
            runs.add(destination: destination, name: run.name, peer: run.peer)
        case ID.changeHost:
            runs.cancel()
            (picked, appliedPick) = (nil, nil)
            loadCandidates()
            draw()
        case ID.fix: runs.fix()
        case ID.openWorkspace:
            runs.openWorkspace()
            panel.hide()
        case ID.copyDetails:
            guard let run = runs.run else { return }
            runs.copy(AddMachineChecklist(events: run.events).details(host: run.host, name: run.name))
        case ID.cancel:
            runs.cancel()
            panel.hide()
        case ID.done: panel.hide()
        default: break
        }
    }

    /// Add: the field's host with the Name typed, else the picked peer's name or the host's short name.
    private func add(_ values: [String: CmuxDialogValue]) {
        guard runs.run == nil, let destination = values[AddMachineCardSpec.ID.destination]?.text, let parsed = runs.parse(destination) else { return }
        let peer = picked.flatMap { $0.destination == destination ? $0 : nil }
        let typed = (values[AddMachineCardSpec.ID.name]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = peer.flatMap { $0.peer?.isEmpty == false ? $0.peer : nil } ?? parsed.shortName
        runs.add(destination: destination, name: typed.isEmpty ? fallback : typed, peer: peer.map { $0.peer ?? "" })
    }

    /// The plain list first (one local tailscale call), then the ssh probe of the person's own machines; a probe
    /// that fails leaves the plain list showing.
    private func loadCandidates() {
        candidatesRead += 1
        let mine = candidatesRead
        candidates = .loading
        // task-owner: one list read per opening or Change Host; a newer read supersedes it (candidatesRead).
        Task { [weak self] in
            guard let self else { return }
            let list = await runs.candidates(probe: false)
            guard mine == candidatesRead else { return }
            candidates = list.map { .loaded($0) } ?? .unavailable
            draw()
            guard list != nil, let probed = await runs.candidates(probe: true), mine == candidatesRead else { return }
            candidates = .loaded(probed)
            draw()
        }
    }
}
