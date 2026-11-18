#if DEBUG
public import AppKit
public import CmuxNextDesign

/// `debug.server_card {card, state}` (DEBUG builds): captures of the native server cards from fixtures, with no
/// account, network, tailnet or machine. `card`: `addServer` (state enter, review, refused, added), `pairInvite`
/// (showing, arrived), `addMachine` (pick, running, failed). Any other card takes them away. Each card's panel keeps
/// its fixture until it hides (no state is kept here).
@MainActor
public struct ServerCardsDebug {
    public init() {}
    static let identifiers: Set<String> = ["cmux.addServer", "cmux.pairInvite", "cmux.addMachine"]

    /// - Parameter qr: The QR of a payload as PNG data (the app's ``PairingQRCode``).
    public static func show(card: String, state: String, over window: NSWindow?, qr: @escaping (String) -> Data?) -> Bool {
        close()
        switch card {
        case "addServer": showAddServer(state, over: window)
        case "pairInvite": showInvite(state, over: window, qr: qr)
        case "addMachine": showAddMachine(state, over: window)
        default: return false
        }
        return true
    }

    public static func close() {
        for panel in NSApp.windows.compactMap({ $0 as? CmuxFloatingDialogPanel }) where identifiers.contains(panel.accessibilityIdentifier()) {
            panel.hide()
        }
    }

    /// The panel keeps `owner` (the fixture's card and what it runs on) until it hides, then lets it go.
    private static func keep(_ panel: CmuxFloatingDialogPanel, _ owner: [AnyObject]) {
        let ownHide = panel.onHide
        panel.onHide = { [weak panel] in
            ownHide?()
            withExtendedLifetime(owner) {}
            panel?.onHide = ownHide
        }
    }

    private static func showAddServer(_ state: String, over window: NSWindow?) {
        let model = ServerModel(source: MockServerSource(scenario: .unpaired))
        model.start()
        model.beginApproval()
        let card = AddServerDialog(model: model)
        card.open(over: window, takeKeys: false)
        keep(card.panel, [card])
        switch state {
        case "review", "added": model.setApprovalCode(MockServerScenario.offerCode)
        case "refused": model.setApprovalCode("7KQ4M2XB")
        default: return
        }
        guard state == "added" else { return }
        // task-owner: the fixture's one approve, once the mock found the server.
        Task {
            for _ in 0..<50 where !model.canApprove { await Task.yield() }
            model.approve()
        }
    }

    private static func showInvite(_ state: String, over window: NSWindow?, qr: @escaping (String) -> Data?) {
        let frames: [PairInviteFrame] = state == "arrived" ? [.pending(expiresAt: nil), .arrived(code: MockServerScenario.offerCode)]
                                                           : [.pending(expiresAt: nil)]
        let approver = ServerModel(source: MockServerSource(scenario: .unpaired))
        approver.start()
        let card = PairInviteDialog(model: PairInviteModel(service: .mock(frames: frames), approver: approver,
                                                           qr: qr))
        card.open(over: window)
        keep(card.panel, [card])
    }

    private static func showAddMachine(_ state: String, over window: NSWindow?) {
        func step(_ step: String, _ state: String, _ detail: String = "", fix: String? = nil) -> String {
            "{\"step\":\"\(step)\",\"state\":\"\(state)\",\"detail\":\"\(detail)\",\"fix\":\(fix.map { "\"\($0)\"" } ?? "null")}"
        }
        let candidates = [
            HostCandidate(name: "studio", dnsName: "studio.tail1.ts.net.", ip: "100.64.0.2", os: "macOS", online: true, alreadyPeer: false, sshOK: true),
            HostCandidate(name: "build-01", dnsName: "build-01.tail1.ts.net.", ip: "100.64.0.3", os: "linux", online: true, alreadyPeer: false,
                          sshOK: false),
            HostCandidate(name: "old-mini", dnsName: "old-mini.tail1.ts.net.", ip: "100.64.0.4", os: "macOS", online: false, alreadyPeer: false),
        ]
        let hold = Hold()
        let services = AddMachineServices(
            parse: AddMachineServices.hostDestination, candidates: { _ in candidates },
            run: { _ in
                AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
                    var lines = [step("reach", "ok", "ssh answered in 42 ms"), step("install", "ok", "cmux-tui 0.42.1")]
                    if state == "failed" {
                        lines.append(step("daemon", "fail", "The daemon did not start.", fix: "Run cmux-tui daemon start on studio."))
                        // The run's report, as cmux-tui prints it before it exits non-zero.
                        let report = "{\"report\":{\"name\":\"Studio\",\"host\":\"studio\",\"ok\":false,\"steps\":[\(lines.joined(separator: ","))]}}"
                        (lines + [report]).forEach { continuation.yield($0) }
                        continuation.finish()
                    } else {
                        lines.forEach { continuation.yield($0) }
                        hold.continuation = continuation
                    }
                }
            },
            install: { _, _ in .failed("debug") }, connect: { _, _ in nil }, record: { _, _ in }, openWorkspace: { _ in }, copy: { _ in })
        let card = AddMachineCard(services: services)
        if state == "pick" {
            card.open(destination: "studio", name: nil, over: window)
        } else {
            card.add(destination: "studio", name: "Studio", over: window)
        }
        keep(card.dialog.panel, [card, hold])
    }

    /// A running fixture's stream, open while its card shows.
    private nonisolated final class Hold {
        var continuation: AsyncThrowingStream<String, any Error>.Continuation?
        deinit { continuation?.finish() }
    }
}

#endif
