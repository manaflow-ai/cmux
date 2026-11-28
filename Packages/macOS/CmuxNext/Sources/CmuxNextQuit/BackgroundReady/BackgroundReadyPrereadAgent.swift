import Foundation
import ServiceManagement

/// `app.backgroundReady`'s login-time pre-read (Warm at Login; Leo 2026-11-18, ask-b2b0f899c1: "well did you guys
/// have more solution ideas tho for getting faster draws and settles?"): a launchd agent registered with
/// `SMAppService.agent` from the plist the bundle carries in `Contents/Library/LaunchAgents` (written by
/// scripts/cmux-next/bundle-server-helper.sh, label `<bundle id>.launch-preread`, so each channel has its own).
/// At login it runs the bundled `bin/cmux-launch-preread` once (RunAtLoad, no KeepAlive, Background, low-priority
/// I/O): it reads the app's executable and frameworks into the page cache, bounded by bytes and time, and exits.
/// Nothing stays running. Registered only while cmux-background-ready says so
/// (``BackgroundReadyRules/registersPrereadAgent(_:)``); every other value unregisters it. A build without the
/// reader carries no plist, and registering is then a no-op that says so.
/// This is the only place that registers the agent.
struct BackgroundReadyPrereadAgent {
    static let plistName = "com.cmux.launch-preread.plist"

    enum Outcome: Equatable {
        /// Already as asked.
        case unchanged
        case registered
        case unregistered
        /// The bundle has no agent plist (no reader in this build).
        case notInBuild
        /// The person must allow it in System Settings > Login Items.
        case requiresApproval
        case failed(String)
    }

    /// The `SMAppService` calls, as a seam.
    struct Service {
        var status: @MainActor () -> SMAppService.Status
        var register: @MainActor () throws -> Void
        var unregister: @MainActor () throws -> Void
        var openLoginItems: @MainActor () -> Void
    }

    var isBundled: @MainActor () -> Bool
    var service: Service

    static func app() -> BackgroundReadyPrereadAgent {
        BackgroundReadyPrereadAgent(
            // SMAppService reads the bundle's Contents/Library/LaunchAgents itself: a build without the plist
            // answers .notFound, so the main actor never stats the bundle.
            isBundled: { SMAppService.agent(plistName: plistName).status != .notFound },
            service: Service(status: { SMAppService.agent(plistName: plistName).status },
                             register: { try SMAppService.agent(plistName: plistName).register() },
                             unregister: { try SMAppService.agent(plistName: plistName).unregister() },
                             openLoginItems: { SMAppService.openSystemSettingsLoginItems() }))
    }

    /// Registers the agent when `registers`, else unregisters it. Idempotent: an agent already in the asked state
    /// is left alone, so following the setting at every launch costs one status read. System Settings opens only
    /// right after a registration that needs approval, not at every launch while it waits.
    @MainActor
    func apply(registers: Bool) -> Outcome {
        let status = service.status()
        let isRegistered = status == .enabled || status == .requiresApproval
        guard registers else {
            guard isRegistered else { return .unchanged }
            do {
                try service.unregister()
                return .unregistered
            } catch {
                return .failed(String(describing: error))
            }
        }
        guard isBundled() else { return .notInBuild }
        switch status {
        case .enabled: return .unchanged
        case .requiresApproval: return .requiresApproval
        default:
            do {
                try service.register()
            } catch {
                return .failed(String(describing: error))
            }
            if service.status() == .requiresApproval {
                service.openLoginItems()
                return .requiresApproval
            }
            return .registered
        }
    }
}
