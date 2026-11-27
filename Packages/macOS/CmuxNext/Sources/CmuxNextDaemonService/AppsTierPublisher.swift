public import CmuxNextBrowserCore
public import CmuxNextCloud
public import Foundation

/// One page's publish (RFD 0003 E-A, `experiments.appsTier`): the target Rust found behind the
/// page, the popover it lays out for each edit, and the run of its command on the preview's
/// machine, read back by Rust. The App only maps these values to the browser's popover.
public struct AppsTierPublisher: Sendable {
    /// Runs a command on a Cloud machine (`CloudMachineIO.exec`).
    public typealias Exec = (_ machine: String, _ command: String, _ timeoutMs: Int) async throws -> CloudExecResult

    /// A cloud exec's own cap (5 minutes): a publish uploads the app's files.
    public static let execTimeoutMs = 300_000

    public let target: AppsTierRules.Target
    private let rules = AppsTierRules()

    /// The page's publish, or nil when the flag is off or the page is no preview this app opened.
    public init?(enabled: Bool, url: URL, title: String?, previews: [AppsTierRules.KnownPreview]) {
        guard enabled, let target = AppsTierRules().target(url: url.absoluteString, title: title, previews: previews) else { return nil }
        self.target = target
    }

    /// The popover for a typed name (nil: the suggested one) and an audience.
    public func popover(name: String?, team: Bool) -> AppsTierRules.Popover? {
        rules.popover(target, AppsTierRules.Draft(name: name, audience: team ? .team : .private))
    }

    /// The popover's form for a typed name and an audience, as the browser draws it.
    public func form(name: String?, team: Bool) -> BrowserPublishForm? {
        popover(name: name, team: team).map { laid in
            BrowserPublishForm(hostLabel: laid.hostLabel, startFrom: laid.startFrom, canPublish: laid.canPublish,
                               problem: laid.problem.map { $0 == "nameEmpty" ? .nameEmpty : .other($0) })
        }
    }

    /// Runs the publish on the preview's machine and reads its answer.
    public func publish(name: String?, team: Bool, exec: Exec) async -> BrowserPublishAnswer {
        let laid = popover(name: name, team: team)
        guard let laid, laid.canPublish else { return .failed(code: "cannot_publish", message: laid?.problem ?? "") }
        let ran: CloudExecResult
        do {
            ran = try await exec(laid.machine, laid.command, Self.execTimeoutMs)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let outcome = rules.outcome(stdout: ran.stdout, stderr: ran.stderr, exit: ran.exitCode) else {
            return .unreadable(exit: ran.exitCode)
        }
        if outcome.published, let link = outcome.url.flatMap(URL.init(string:)) { return .published(link) }
        return .failed(code: outcome.code ?? outcome.kind, message: outcome.message ?? "")
    }
}
