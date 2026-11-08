public import Foundation

/// The Server panel's switch and Show Pairing Code on this Mac (plans/cmux-next/server.md 3):
/// `cmux server up|down` and the `cmux server pair` wait, through a CLI runner the App injects.
///
/// The switch settles its intent when the CLI exits. Show Pairing Code starts one pairing wait
/// (a second click joins it) and settles once the CLI prints the code; the code itself reaches
/// the panel through `server status --json`, which reads the enrollment record. The wait keeps
/// running until the code is approved or expires; ``stop()`` ends it.
///
/// ```swift
/// let controls = LocalServerControls(run: { _ in 0 }, wait: { _, line in line(#"{"code":"7KQ4-M2XD"}"#); return 0 },
///                                    settle: { key, reject in print(key, reject ?? "ok") }, refresh: {})
/// _ = controls.send(ServerIntent(kind: .showPairingCode))
/// ```
@MainActor
public final class LocalServerControls {
    /// Runs the CLI once with `arguments`: its exit status, or nil when it could not start or ran out of time.
    public typealias Run = @concurrent @Sendable (_ arguments: [String]) async -> Int32?
    /// Runs `server pair --json` until approval or expiry, passing each stderr line as the CLI
    /// writes it: its exit status, or nil when it could not start.
    public typealias Wait = @concurrent @Sendable (_ arguments: [String], _ line: @escaping @Sendable (String) -> Void) async -> Int32?

    /// The arguments of the pairing wait.
    public nonisolated static let pairArguments = ["server", "pair", "--json"]

    /// The arguments of the switch: `server up` turns the server on, `server down` off.
    public nonisolated static func switchArguments(on: Bool) -> [String] { ["server", on ? "up" : "down", "--json"] }

    private let run: Run
    private let wait: Wait
    private let settle: @MainActor (_ key: String, _ reject: String?) -> Void
    private let refresh: @MainActor () -> Void
    private var switches: [String: Task<Void, Never>] = [:]
    private var pairing: Task<Void, Never>?
    /// Show Pairing Code intents that settle when the running wait prints its code.
    private var pairingKeys: [String] = []

    /// Creates the controls.
    ///
    /// - Parameter run: Runs the bundled CLI once (the switch).
    /// - Parameter wait: Runs the pairing wait with its progress lines.
    /// - Parameter settle: Answers an intent: `reject` is nil on success, else the text to show.
    /// - Parameter refresh: Reads the server status again (the wait ended).
    public init(run: @escaping Run, wait: @escaping Wait, settle: @escaping @MainActor (_ key: String, _ reject: String?) -> Void,
                refresh: @escaping @MainActor () -> Void) {
        self.run = run
        self.wait = wait
        self.settle = settle
        self.refresh = refresh
    }

    /// Takes `intent` when it is the switch or Show Pairing Code.
    ///
    /// - Returns: false for any other intent, which stays with the caller.
    public func send(_ intent: ServerIntent) -> Bool {
        switch intent.kind {
        case let .setEnabled(on):
            let run = run, key = intent.key
            // task-owner: LocalServerControls, one `server up|down` per intent; cancelled by stop().
            switches[key] = Task { [weak self] in
                let status = await run(Self.switchArguments(on: on))
                guard let self, !Task.isCancelled else { return }
                switches[key] = nil
                settle(key, status == 0 ? nil : (on ? ServerStrings.startFailed : ServerStrings.stopFailed))
            }
            return true
        case .showPairingCode:
            pairingKeys.append(intent.key)
            startPairing()
            return true
        default:
            return false
        }
    }

    /// Ends the switch runs and the pairing wait; their intents stay unsettled.
    public func stop() {
        for task in switches.values { task.cancel() }
        switches = [:]
        pairing?.cancel()
        pairing = nil
        pairingKeys = []
    }

    private func startPairing() {
        guard pairing == nil else { return }
        let wait = wait
        // task-owner: LocalServerControls, the one `server pair` wait; cancelled by stop().
        pairing = Task { [weak self] in
            let (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(16))
            async let status = Self.waitForApproval(wait, continuation)
            for await line in lines where Self.showsCode(line) {
                self?.settlePairing(reject: nil)
            }
            let exit = await status
            guard let self, !Task.isCancelled else { return }
            pairing = nil
            settlePairing(reject: exit == 0 ? nil : ServerStrings.pairStartFailed)
            refresh()
        }
    }

    @concurrent private nonisolated static func waitForApproval(_ wait: Wait, _ lines: AsyncStream<String>.Continuation) async -> Int32? {
        defer { lines.finish() }
        return await wait(pairArguments) { lines.yield($0) }
    }

    /// Whether a `server pair --json` progress line carries the code (or an invite's check words) to show.
    nonisolated static func showsCode(_ line: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return object["code"] is String || object["invited"] as? Bool == true
    }

    private func settlePairing(reject: String?) {
        let keys = pairingKeys
        pairingKeys = []
        for key in keys { settle(key, reject) }
    }
}
