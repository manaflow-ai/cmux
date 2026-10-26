/// Pauses the frame clients that the device's power state does not let run, and starts them again
/// when it does (Low Power Mode, or a serious or critical thermal state: ``PowerState/capsFrameRate``).
///
/// A client made with a gate (``FrameClient/init(owner:isAnimation:rate:on:power:onFrame:)``) asks
/// it on every activation: while its class is paused (``FrameRateClass/limited(by:)``, today only
/// ``FrameRateClass/ambient``) it stays active for its owner but leaves its scheduler, so it gets no
/// frame and does not keep a display link up. ``FrameRateClass/motion`` and ``FrameRateClass/ui``
/// clients are never paused, so the link rate the scheduler decides among the clients left is at
/// most 60 Hz unless motion runs. Chrome throttles every frame sink under Energy Saver
/// (`StartThrottlingAllFrameSinks`, `content/public/browser/frame_rate_throttling.h`); cmux keeps
/// motion that follows the hand at full rate and pauses only loops, as LoopVisibility does for a
/// hidden view.
///
/// The power state is injected: the composition root makes one gate for the app and, with the
/// `frameRatePowerCaps` feature on, sets ``power`` from the app's existing Low Power Mode and
/// thermal-state observers (no observer here). With the feature off it stays nominal and nothing
/// pauses. Tests set ``power`` directly.
///
/// ```swift
/// let gate = FramePowerGate()
/// let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler, power: gate) { _ in true }
/// spinner.activate()
/// gate.power = PowerState(isLowPowerMode: true) // spinner.isPowerPaused == true
/// ```
@MainActor
public final class FramePowerGate {
    /// The power state the gate applies; a change pauses or resumes the active clients behind it.
    public var power: PowerState {
        didSet {
            guard power != oldValue else { return }
            // Power changes are rare (a mode switch, a thermal step): O(active gated clients) is fine.
            for client in Array(clients.values) {
                client.powerDidChange(admitted: admits(client))
            }
        }
    }

    /// Active clients behind this gate, ticking or paused. An active client is held (as its
    /// scheduler holds it), so a paused client is not lost; it leaves when its owner deactivates it.
    private var clients: [ObjectIdentifier: FrameClient] = [:]

    /// - Parameter power: The starting power state (nominal: nothing paused).
    public init(power: PowerState = PowerState()) {
        self.power = power
    }

    /// Owners of the active clients that the power state pauses now (debug.wakeups).
    public var pausedClients: [String] {
        clients.values.filter(\.isPowerPaused).map(\.owner).sorted()
    }

    /// Whether `client`'s class may tick under the current power state.
    func admits(_ client: FrameClient) -> Bool {
        client.rate.limited(by: power) != nil
    }

    /// `client` became active.
    func register(_ client: FrameClient) {
        clients[ObjectIdentifier(client)] = client
    }

    /// `client` went idle.
    func unregister(_ client: FrameClient) {
        clients[ObjectIdentifier(client)] = nil
    }
}
