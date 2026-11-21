import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDesign
import Foundation

/// Team-visible Cloud sessions (cloud multiplayer lane D) for the app: the shared store, the
/// publisher, the `cloud.team.*` actions (``bind(into:reason:)``), the
/// `cmux://cloud/session|workspace/…` link (``openLink(team:machine:session:kind:intent:)``) and the
/// sidebar's Team section (``makeSectionView()``). AppServices owns one; it reaches the app only
/// through ``CloudTeamHost``.
@MainActor
public final class CloudTeamFeature {
    /// The Team section's contribution id (`<owner>#<section>`, as the sidebar document names an
    /// app section); `cloud.team.showSection` adds a section of it.
    public static let contribution = "cmux/team#team"

    public let store: CloudTeamSessionStore
    let publisher: CloudTeamPublisher
    weak var host: (any CloudTeamHost)?
    weak var registry: ActionRegistry?

    public init(host: any CloudTeamHost) {
        self.host = host
        let store = CloudTeamSessionStore(transport: Self.transport(host), currentUser: { [weak host] in host?.cloudTeamUserID },
                                          activeTeam: { [weak host] in host?.cloudTeamID })
        self.store = store
        publisher = CloudTeamPublisher(host: host, store: store)
        store.setTeam(host.cloudTeamID)
        // task-owner: follows the account's active team for the app's life; the store drops the old team's rows.
        Task { [weak host, weak store] in
            for await team in ObservationStream({ host?.cloudTeamID }) {
                guard let store else { return }
                store.setTeam(team)
            }
        }
    }

    /// The person's Cloud chat started (CloudStartSession): the team hears of it now.
    public func chatStarted() {
        publisher.flush()
    }

    /// The sidebar's Team section view (one per window).
    public func makeSectionView() -> CloudTeamHostingView {
        CloudTeamHostingView(store: store, tokens: { [weak host] in host?.cloudTeamTokens ?? ThemeScope.app.tokens },
                             perform: { [weak registry] id, arguments in
                                 _ = registry?.perform(id, invocation: ActionInvocation(arguments: arguments, origin: .user))
                             }, open: { [weak self] row in
                                 self?.openLink(team: row.team, machine: row.vm, session: row.session, kind: row.kind, intent: .raise)
                             }, menu: { [weak self] row, members in
                                 self?.makeRowMenu(row, members: members)
                             })
    }

    /// The store's calls through the host, its refusals as the store's codes.
    static func transport(_ host: any CloudTeamHost) -> CloudTeamSessionStore.Transport {
        { [weak host] path, body, team in
            guard let host else { throw CloudTeamError(code: CloudTeamError.signedOut, message: CloudTeamStrings.signedOut) }
            do {
                return try await host.cloudTeamCall(path, body, team: team)
            } catch FeedServiceError.signedOut {
                throw CloudTeamError(code: CloudTeamError.signedOut, message: CloudTeamStrings.signedOut)
            } catch let FeedServiceError.owner(code, message) {
                throw CloudTeamError(code: code, message: message.isEmpty ? CloudTeamStrings.refused(code) : message)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CloudTeamError(code: CloudTeamError.unreachable, message: CloudTeamStrings.unreachable)
            }
        }
    }
}
