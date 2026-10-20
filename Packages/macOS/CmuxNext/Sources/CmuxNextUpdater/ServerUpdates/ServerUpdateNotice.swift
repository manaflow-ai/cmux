public import CmuxNextDesign
import Foundation

/// "Restart cmux-tui to use new features": one server on one host lacks capabilities this app can
/// use. The app keeps working without them; the notice names what a restart gains.
public nonisolated struct ServerUpdateNotice: Sendable, Equatable, Identifiable {
    /// Which server.
    public var kind: ServerKind
    /// Where it runs.
    public var host: ServerHost
    /// The running server's build, if known.
    public var serverBuild: String?
    /// Every capability the restart would add, sorted.
    public var missingCapabilities: [String]
    /// The named features among them, in catalog order.
    public var gainedFeatures: [ServerFeature]
    /// What a restart keeps and loses.
    public var impact: ServerRestartImpact

    /// One notice per server, host and server build: a snooze covers that build only.
    public var id: String { "\(kind.rawValue)|\(host.key)|\(serverBuild ?? "unknown")" }

    /// The server as the person reads it: "cmux-tui", or "cmux-tui on cmux-mini".
    public var serverLabel: String {
        switch host {
        case .local: kind.displayName
        case .remote(let name): UpdaterStrings.format("server.label.onHost", "%1$@ on %2$@", kind.displayName, name)
        }
    }

    /// How many features are named in the toast at most.
    public static let namedLimit = 3

    /// The toast's sentence.
    public var toastMessage: String {
        let named = gainedFeatures.prefix(Self.namedLimit).map(\.title)
        let more = missingCapabilities.count - named.count
        guard !named.isEmpty else {
            return UpdaterStrings.format("server.toast.generic", "Restart %@ to use new features", serverLabel)
        }
        if more > 0 {
            let list = named.joined(separator: UpdaterStrings.text("server.list.separator", ", "))
            return UpdaterStrings.format("server.toast.featuresMore", "Restart %1$@ to use new features: %2$@ and %3$lld more",
                                         serverLabel, list, Int64(more))
        }
        let list = ListFormatter.localizedString(byJoining: named)
        return UpdaterStrings.format("server.toast.features", "Restart %1$@ to use new features: %2$@", serverLabel, list)
    }

    /// The toast's button, which opens the confirm.
    public var restartButtonTitle: String {
        UpdaterStrings.format("server.button.restart", "Restart %@…", kind.displayName)
    }

    /// The confirm: what survives, what is lost, Cancel and Restart.
    public var confirmSpec: CmuxDialogSpec {
        let restart = CmuxDialogButton(id: "restart", title: UpdaterStrings.text("server.confirm.restart", "Restart"),
                                       role: impact.isDestructive ? .destructive : .default)
        return CmuxDialogSpec(title: UpdaterStrings.format("server.confirm.title", "Restart %@?", serverLabel),
                              lines: impact.kept + impact.lost,
                              buttons: [.cancel(), restart],
                              identifier: "cmux.server-restart.\(kind.rawValue)")
    }
}
