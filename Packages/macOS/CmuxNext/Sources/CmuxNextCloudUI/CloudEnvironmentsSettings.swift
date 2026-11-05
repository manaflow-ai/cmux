public import Foundation
public import Observation

/// Settings > Accounts > Cloud Environments (plans/cmux-next/cloud-environments-DESIGN.md): the team's
/// environments through the Cloud app server (`cloud.environment.*` on CloudDO), on the cmux-next
/// Cloud path only. Save is a plain mutation; Build and Delete are money and destructive ops, so the
/// person confirms natively first. The list is read on open and on Refresh; nothing polls.
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
    private let strings = CloudEnvironmentStrings()

    public init(available: @escaping @MainActor () -> Bool, list: @escaping List, save: @escaping Save,
                approvedCall: @escaping ApprovedCall, confirm: @escaping Confirm) {
        self.available = available
        self.list = list
        self.save = save
        self.approvedCall = approvedCall
        self.confirm = confirm
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
            return Result()
        } catch {
            return Result(error: String(describing: error))
        }
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
        var args: [String: String?] = [:]
        if let id = request.id { args["environment"] = .some(id) }
        if let name = request.name { args["name"] = .some(name) }
        if let repo = request.repo { args["repo"] = repo.isEmpty ? .some(nil) : .some(repo) }
        if let script = request.setupScript { args["setup_script"] = .some(script) }
        return try JSONEncoder().encode(args)
    }
}
