import AppKit
import CmuxCloud
import CmuxCloudBannerCore
import Foundation
import Observation

/// The contextual Cloud tips: what earns each one, its copy, and the one
/// queue every Cloud panel reads.
///
/// Each tip is earned by state the panel already shows (a ready machine, a
/// forwarded port, an agent failure with no provider key saved) and retires
/// for good once dismissed, acted on, or seen for a moment
/// (``CloudHintsQueue``). The panel shows at most one, in its footer, never
/// while it is loading, failing, showing Get started, or showing a popover.
@MainActor
@Observable
final class CloudHintsCenter {
    static let shared = CloudHintsCenter()

    /// The tips; a higher ``priority`` shows first.
    enum Kind: String, CaseIterable {
        /// An agent failed and Cloud Secrets holds no agent API key.
        case agentKey = "agentKey.v1"
        /// A server on a machine is forwarded; previews start private.
        case portPrivate = "portPrivate.v1"
        /// The first machine is ready; a shortcut opens a terminal on it.
        case machineTerminal = "machineTerminal.v1"

        var priority: Int {
            switch self {
            case .agentKey: return 30
            case .portPrivate: return 20
            case .machineTerminal: return 10
            }
        }
    }

    /// A machine a tip names.
    struct MachineRef: Equatable {
        var id: String
        var label: String
    }

    /// A forwarded port a tip names.
    struct PortRef: Equatable {
        var machineID: String
        var machineLabel: String
        var port: Int
    }

    /// What the panel knows right now, reduced to what earns a tip.
    struct Facts: Equatable {
        /// The first ready machine.
        var readyMachine: MachineRef?
        /// The first forwarded port on a Cloud machine.
        var forwardedPort: PortRef?
        /// An agent on some machine reported a failure the person has not read.
        var hasUnreadAgentFailure = false
        /// Cloud Secrets holds an API key an agent reads.
        var hasAgentKey = false
    }

    let queue: CloudHintsQueue
    /// The facts the latest offer read, so each tip can name its subject.
    private(set) var facts = Facts()

    init(queue: CloudHintsQueue? = nil) {
        self.queue = queue ?? CloudHintsQueue(
            dismissals: AppDelegate.shared?.cloudBannerDismissalStore ?? CloudBannerDismissalStore(defaults: .standard)
        )
    }

    /// Offers every tip the facts earn and withdraws the ones whose reason
    /// went away (a key was saved, the port closed), without retiring them.
    func update(_ facts: Facts) {
        guard facts != self.facts else { return }
        self.facts = facts
        if let machine = facts.readyMachine {
            queue.offer(CloudHint(id: Kind.machineTerminal.rawValue, priority: Kind.machineTerminal.priority, subject: machine.label))
        } else {
            queue.withdraw(Kind.machineTerminal.rawValue)
        }
        if let port = facts.forwardedPort {
            queue.offer(CloudHint(id: Kind.portPrivate.rawValue, priority: Kind.portPrivate.priority, subject: String(port.port)))
        } else {
            queue.withdraw(Kind.portPrivate.rawValue)
        }
        if facts.hasUnreadAgentFailure, !facts.hasAgentKey {
            queue.offer(CloudHint(id: Kind.agentKey.rawValue, priority: Kind.agentKey.priority))
        } else {
            queue.withdraw(Kind.agentKey.rawValue)
        }
    }

    /// Opening Cloud Secrets by any path is what the key tip teaches.
    func noteSecretsOpened() {
        queue.retire(Kind.agentKey.rawValue)
    }

    /// The tip's copy and action, bound to the current facts.
    func presentation(for hint: CloudHint) -> CloudHintPresentation? {
        guard let kind = Kind(rawValue: hint.id) else { return nil }
        switch kind {
        case .machineTerminal:
            guard let machine = facts.readyMachine else { return nil }
            let shortcut = KeyboardShortcutSettings.shortcut(for: .newCloudWorkspace)
            let detail = shortcut.isUnbound || shortcut.hasChord
                ? String(
                    format: String(localized: "cloudHints.machineTerminal.detailCLI", defaultValue: "Open its shell with %@."),
                    CloudTeachingAction.openTerminal.cliCommand(machine: machine.label)
                )
                : String(
                    format: String(localized: "cloudHints.machineTerminal.detail", defaultValue: "%@ opens a terminal on it anytime."),
                    shortcut.displayString
                )
            return CloudHintPresentation(
                id: hint.id,
                symbolName: "terminal",
                title: String(
                    format: String(localized: "cloudHints.machineTerminal.title", defaultValue: "%@ is ready"),
                    machine.label
                ),
                detail: detail,
                perform: {
                    MachineRowActions.bound(onDidMutate: {}).openShell(machine.id)
                }
            )
        case .portPrivate:
            guard let port = facts.forwardedPort else { return nil }
            // Without a share flow in this build the tip only teaches.
            var perform: (@MainActor () -> Void)?
            if let share = CloudTeachingActionRegistry.shared.sharePort {
                perform = { _ = share(port.machineID, port.machineLabel, port.port) }
            }
            return CloudHintPresentation(
                id: hint.id,
                symbolName: "lock",
                title: String(localized: "cloudHints.portPrivate.title", defaultValue: "Previews are private"),
                detail: String(
                    format: String(localized: "cloudHints.portPrivate.detail", defaultValue: "Share port %ld to send someone a link."),
                    port.port
                ),
                perform: perform
            )
        case .agentKey:
            return CloudHintPresentation(
                id: hint.id,
                symbolName: "key",
                title: String(localized: "cloudHints.agentKey.title", defaultValue: "Add your key in Cloud Secrets"),
                detail: String(localized: "cloudHints.agentKey.detail", defaultValue: "An agent reported an error. Keys here reach every machine."),
                perform: {
                    let window = NSApp.keyWindow ?? NSApp.mainWindow
                    _ = AppDelegate.shared?.openCloudSecrets(preferredWindow: window, debugSource: "cloudHints.agentKey")
                }
            )
        }
    }
}

/// One tip, ready to draw: an icon, a verb-led title, one muted line, and the
/// action a click on the row runs (nil: the row only teaches).
struct CloudHintPresentation {
    let id: String
    let symbolName: String
    let title: String
    let detail: String
    let perform: (@MainActor () -> Void)?
}
