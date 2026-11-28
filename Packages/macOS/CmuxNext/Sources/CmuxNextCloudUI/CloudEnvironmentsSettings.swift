public import Foundation
public import Observation

/// Settings > Accounts > Cloud Environments (plans/cmux-next/cloud-environments-DESIGN.md): the team's
/// environments through the Cloud app server (`cloud.environment.*` on CloudDO), on the cmux-next
/// Cloud path only. Save is a plain mutation; Build and Delete are money and destructive ops, so the
/// person confirms natively first. The list is read on open and on Refresh; nothing polls.
///
/// Settings > Cloud > Default Image (`cloud.defaultImage`, cmux#51731) rebuilds by itself: the image's
/// snapshot goes stale when the base image it was built on is rebaked (its build digest, the design's
/// section 3), as it is when the agents a Cloud machine carries change. A read that finds the Default
/// Image stale builds it again with no confirmation (picking it as the Default Image is the person's
/// ask for it to stay current), once per stale read; any other environment's Build still asks.
///
/// The app passes JSON (`Data`) through its seams, so this type needs no wire or daemon types:
///
/// ```swift
/// let model = CloudEnvironmentsSettings(available: { true },
///     list: { try JSONEncoder().encode(await cloud.appOps("cloud.environment.list", [:], nil, .script)) },
///     save: { args in _ = try await cloud.appOps("cloud.environment.set", try JSONDecoder().decode(JSONValue.self, from: args), UUID().uuidString, .user) },
///     approvedCall: { op, id, confirm in try await cloud.appServerApprovedCall(op, args: ["environment": .string(id)], confirm: confirm) },
///     confirm: { title, body, button in await sheet(title, body, button) })
/// ```
@MainActor @Observable
public final class CloudEnvironmentsSettings {
    /// What `cmux.settings.environments.state` answers.
    public struct State: Encodable, Equatable, Sendable {
        /// False on the classic Cloud path or while signed out: the card explains instead.
        public var available = false
        public var loading = false
        public var environments: [CloudEnvironmentRow] = []
        /// The last refresh's failure.
        public var error: String?
    }

    /// A run's answer: nil error on success and on a declined confirmation.
    public struct Result: Encodable, Equatable, Sendable {
        public var error: String?
    }

    /// `cloud.environment.list`'s answer as JSON.
    public typealias List = @MainActor () async throws -> Data
    /// `cloud.environment.set` with these JSON args (a fresh key, origin user).
    public typealias Save = @MainActor (_ args: Data) async throws -> Void
    /// `op` on environment `id` through the approval loop, `confirm` its native confirmation;
    /// false when the person declined (nothing more was sent).
    public typealias ApprovedCall = @MainActor (_ op: String, _ id: String, _ confirm: @escaping @MainActor () async -> Bool) async throws -> Bool
    /// The native confirmation: title, body, button; true only for the person's click.
    public typealias Confirm = @MainActor (_ title: String, _ body: String, _ button: String) async -> Bool

    public private(set) var state = State()
    private let available: @MainActor () -> Bool
    private let list: List
    private let save: Save
    private let approvedCall: ApprovedCall
    private let confirm: Confirm
    /// Settings > Cloud > Default Image's environment id; nil (or `auto`) for none.
    private let defaultImage: @MainActor () -> String?
    /// The Default Image ids a read found stale and rebuilt: one build per stale snapshot, so a failed or
    /// still-stale answer never builds again in a loop. A read that finds it no longer stale forgets it.
    private var rebuilt: Set<String> = []
    private let strings = CloudEnvironmentStrings()

    public init(available: @escaping @MainActor () -> Bool, list: @escaping List, save: @escaping Save,
                approvedCall: @escaping ApprovedCall, confirm: @escaping Confirm,
                defaultImage: @escaping @MainActor () -> String? = { nil }) {
        self.available = available
        self.list = list
        self.save = save
        self.approvedCall = approvedCall
        self.confirm = confirm
        self.defaultImage = defaultImage
    }

    /// Runs one gesture, then reads the list again.
    public func run(_ request: CloudEnvironmentsRun) async -> Result {
        guard available() else {
            state = State()
            return request.action == .refresh ? Result() : Result(error: strings.unavailable)
        }
        do {
            switch request.action {
            case .refresh:
                break
            case .save:
                try await save(Self.saveArgs(request))
            case .build, .delete:
                guard let id = request.id else { return Result(error: strings.unknown) }
                let name = state.environments.first { $0.id == id }?.name ?? id
                let build = request.action == .build
                let (title, body, button) = build
                    ? (strings.buildTitle(name), strings.buildBody, strings.buildButton)
                    : (strings.deleteTitle(name), strings.deleteBody, strings.deleteButton)
                let confirm = confirm
                let sent = try await approvedCall(build ? "cloud.environment.build" : "cloud.environment.delete", id) {
                    await confirm(title, body, button)
                }
                if !sent { return Result() }
            }
            try await refresh()
            await rebuildStaleDefaultImage()
            return Result()
        } catch {
            return Result(error: String(describing: error))
        }
    }

    /// Builds the Default Image again when the last read found its snapshot stale (see the type's notes), then reads again.
    /// A refused build is the Cloud Environments card's to show (its row reads failed); the read it ran on still answers.
    private func rebuildStaleDefaultImage() async {
        guard let id = defaultImage(), !id.isEmpty, id != "auto",
              let row = state.environments.first(where: { $0.id == id }) else { return }
        switch row.status {
        case "stale": break
        // Still building (or a stale answer of a read that began before the build): nothing to do and nothing to forget.
        case "building": return
        default: rebuilt.remove(id); return
        }
        guard rebuilt.insert(id).inserted else { return }
        guard (try? await approvedCall("cloud.environment.build", id, { true })) == true else { return }
        try? await refresh()
    }

    private struct ListAnswer: Decodable { var environments: [CloudEnvironmentRow] }

    private func refresh() async throws {
        state.loading = true
        defer { state.loading = false }
        do {
            let answer = try JSONDecoder().decode(ListAnswer.self, from: try await list())
            state = State(available: true, environments: answer.environments)
        } catch {
            state.available = true
            state.error = String(describing: error)
            throw error
        }
    }

    /// `cloud.environment.set`'s params for a Save: only the fields the page sent; an empty repo clears it.
    static func saveArgs(_ request: CloudEnvironmentsRun) throws -> Data {
        try JSONEncoder().encode(SaveArgs(request: request))
    }

    private struct SaveArgs: Encodable {
        let request: CloudEnvironmentsRun
        private enum CodingKeys: String, CodingKey { case environment, name, repo, env, setupScript = "setup_script" }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(request.id, forKey: .environment)
            try c.encodeIfPresent(request.name, forKey: .name)
            if let repo = request.repo {
                if repo.isEmpty { try c.encodeNil(forKey: .repo) } else { try c.encode(repo, forKey: .repo) }
            }
            try c.encodeIfPresent(request.setupScript, forKey: .setupScript)
            try c.encodeIfPresent(request.env, forKey: .env)
        }
    }
}
