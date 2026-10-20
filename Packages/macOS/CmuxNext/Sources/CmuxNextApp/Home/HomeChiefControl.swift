import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextRemote
import Foundation
import os

/// Which brain answers a Home Chief conversation, and the owner's control
/// of it: the engine source of the settings panel and `chief.stop`. This
/// Mac's Chief goes through this Mac's Chief owner daemon (which forwards to
/// its brain's tools socket); a cloud Chief goes through the daemon of the
/// paired server its brain is placed on (the owner session the app holds).
@MainActor
struct HomeChiefControl {
    let services: AppServices
    let conversation: ConversationID
    /// The default Chief's mux home (this build's Chief home).
    let muxHome: URL
    /// The local Chief this conversation is with when it is not the default
    /// (chief-brains-v1, cx-327wl): every control names it in `chief`, so the
    /// panel, Stop and the avatar act on that Chief's own brain, never the
    /// default's. Nil: the default Chief (or a cloud Chief).
    var chief: String?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    /// The `shared stop action` (palette, the compose bar's stop button, Esc
    /// and Cmd-. in the field): the key window's Home view stops its Chief.
    static let stopAction: ActionID = "home.stopChief"
    static let stopNotification = Notification.Name("HomeHostView.stopChief")

    var isCloud: Bool { services.home.isCloudConversation(conversation) }

    /// The paired server that runs this cloud Chief's brain (`brain_place`).
    var server: ServerMachineSession? {
        guard isCloud, let host = services.home.cloudChief?.brainPlace?.host else { return nil }
        return services.machines.servers.first { $0.reach.hostID == host }
    }

    /// The daemon in front of the brain; nil while it is not connected.
    var connection: DaemonConnection? {
        isCloud ? server?.daemon.connection : services.home.connection
    }

    /// The `chief` field of this conversation's controls: a local Chief that
    /// is not the default; nil for the default and a cloud Chief.
    var named: String? { isCloud ? nil : chief }

    /// The mux home of the brain that answers here (ChiefHome.brainHome).
    var brainHome: URL { ChiefHome.brainHome(muxHome: muxHome, chief: named) }

    /// The settings panel's source for this Chief.
    func engineSource() -> any HomeChiefEngineSource {
        let files = HomeChiefFiles(muxHome: brainHome)
        let services = services
        guard isCloud else {
            // The owner daemon starts a named Chief's brain (chief_brains.rs);
            // only the default Chief's host is this app's to start.
            let named = named
            return HomeChiefLocalEngine(files: files, connection: { [weak services] in services?.home.connection },
                                        startBrain: { [weak services] asked in
                                            named == nil ? services?.home.brain.ensure(asked: asked) ?? false : false
                                        }, chief: named)
        }
        let conversation = conversation
        let muxHome = muxHome
        return HomeChiefRemoteEngine(
            connection: { HomeChiefControl(services: services, conversation: conversation, muxHome: muxHome).connection },
            place: server?.name ?? services.home.cloudChief?.brainPlace?.host,
            files: files)
    }

    /// `chief.stop` on this Chief's brain; nil when it stopped (or had no
    /// turn), else why not.
    func stop() async -> HomeChiefEngineError? {
        guard let connection else { return .unreachable }
        do {
            let stopped = try await ChiefControlClient(connection).stopChief(chief: named)
            Self.logger.info("home: chief.stop answered stopped=\(stopped, privacy: .public)")
            return nil
        } catch let error as ChiefControlError {
            Self.logger.error("home: chief.stop failed: \(String(describing: error), privacy: .public)")
            return HomeChiefEngineError(error)
        } catch {
            return .other(String(describing: error))
        }
    }
}
