public import AppKit
import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings
import Observation

/// Settings > Chief > Credential Vault (cmux issue 26412): every secret's name, who may use it and
/// its last use, with Add, Replace and Delete. Never a value: the card reads the vault's index, and
/// Add and Replace take the value on the secure entry sheet, straight into the Keychain.
///
/// The board keeps the vault's index for the host lists (`credential_vault`). It reads it off the
/// main actor and again after every change, the CLI's too (``CredentialVault/onChange(_:)``), so the
/// page's host-lists watch re-sends it.
@MainActor @Observable
public final class CredentialVaultBoard {
    /// Every secret's record by name; empty until the first read.
    public private(set) var entries: [String: CredentialVault.Entry] = [:]
    public private(set) var loaded = false
    /// Why the last read failed (an unreadable index), in the person's words.
    public private(set) var failure: String?

    @ObservationIgnored public let vault: CredentialVault
    @ObservationIgnored private var started = false
    @ObservationIgnored private let enabled: @MainActor () -> Bool
    /// The newest read: an older one that ends later never replaces it.
    @ObservationIgnored private var generation = 0

    public init(vault: CredentialVault,
                enabled: @escaping @MainActor () -> Bool = { CredentialVault.rolloutEnabled.value }) {
        self.vault = vault
        self.enabled = enabled
        vault.onChange { [weak self] in
            // task-owner: one read of the index; it ends by itself
            Task { @MainActor in self?.reload() }
        }
    }

    /// Reads the index again; the task ends once the board shows it.
    @discardableResult
    public func reload() -> Task<Void, Never> {
        started = true
        generation += 1
        let generation = generation, vault = vault
        // task-owner: one read of the index; it ends by itself
        return Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try vault.list() } }.value
            guard let self, generation == self.generation else { return }
            switch result {
            case .success(let entries):
                self.entries = entries
                failure = nil
            case .failure(let error as CredentialVault.Failure):
                failure = VaultControl.error(error).message
            case .failure(let error):
                failure = error.localizedDescription
            }
            loaded = true
        }
    }

    /// The host lists' `credential_vault`: `{loaded, error, secrets: [{name, scope, note, uses,
    /// updated_ms, last_used_ms, last_used_by}]}` by name. The first read starts here.
    public var hostJSON: JSONValue {
        if !started { reload() }
        return [
            "loaded": .bool(loaded),
            "error": failure.map(JSONValue.string) ?? .null,
            "secrets": .array(entries.sorted { $0.key < $1.key }.map { VaultControl.json(name: $0.key, $0.value) }),
        ]
    }
}

/// The card's gestures, on the person's click on Settings only: `add {}`, `replace {name}` (the
/// secure entry sheet), `remove {name}` (a confirmation first) and `scope {name, scope}`. Each
/// answers `{done}`: false when the person cancelled.
@MainActor
public final class CredentialVaultPageRoute: PageProvider {
    public nonisolated static let prefix = "cmux.settings.credential_vault."

    private let board: CredentialVaultBoard
    private let enabled: @MainActor () -> Bool
    private let window: @MainActor () -> NSWindow?
    /// The gesture the last call used (``PageCallContext/gestureEvent``).
    private var spentGesture: TimeInterval?
    /// The person's approval of a scope change that lets agents use a secret (nil: the approval sheet).
    private let approve: (@MainActor (CredentialVault.Approval) async -> Bool)?

    /// `window`: the window Settings shows in, for the sheets. `approve`: tests answer the approval.
    public init(board: CredentialVaultBoard, window: @escaping @MainActor () -> NSWindow?,
                enabled: @escaping @MainActor () -> Bool = { CredentialVault.rolloutEnabled.value },
                approve: (@MainActor (CredentialVault.Approval) async -> Bool)? = nil) {
        self.board = board
        self.enabled = enabled
        self.window = window
        self.approve = approve
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let action = op.hasPrefix(Self.prefix) ? String(op.dropFirst(Self.prefix.count)) : ""
        guard ["add", "replace", "remove", "scope"].contains(action) else { throw PageError.unknownOp(op) }
        // One call per real click or key in Settings: a scripted call riding the same event is refused.
        guard context.page == PageDescriptor.settings.id, context.userGesture, let event = context.gestureEvent,
              event != spentGesture else {
            throw PageError(code: "vault.user_only", message: CredentialVaultStrings.agentsMayNotWrite)
        }
        spentGesture = event
        let vault = board.vault
        let person = CredentialVault.Caller(consumer: .user, label: CredentialVaultStrings.settingsCaller)
        let done: Bool
        switch action {
        case "add":
            done = try await enter(CredentialVault.EntryRequest(name: "", reason: nil, requester: "", replaces: false), person: person)
        case "replace":
            let name = try existing(params)
            let scope = board.entries[name]?.scope ?? CredentialVault.Consumer.allCases
            done = try await enter(CredentialVault.EntryRequest(name: name, reason: nil, requester: "", replaces: true, scope: scope),
                                   person: person)
        case "remove":
            let name = try existing(params)
            guard let window = window() else { throw PageError.unavailable("Settings has no window") }
            guard await Self.confirmDelete(name, in: window) else { return ["done": false] }
            _ = try await Self.off { try vault.remove(name, by: person) }
            done = true
        default:
            let name = try existing(params)
            guard case .array(let items)? = params["scope"] else { throw PageError.invalidParams(CredentialVaultStrings.badScope) }
            let scope = items.compactMap { $0.stringValue.flatMap(CredentialVault.Consumer.init(rawValue:)) }
            guard scope.count == items.count, !scope.isEmpty else { throw PageError.invalidParams(CredentialVaultStrings.badScope) }
            // The board can lag a revocation. Check authorization under the write's own lock,
            // against the protected scope, before committing a gesture that may be synthetic.
            let applied = try await Self.off {
                do {
                    try vault.setScope(name, scope: scope, by: person, agentsApproved: false)
                    return true
                } catch CredentialVault.Failure.needsApproval(_) {
                    return false
                }
            }
            if !applied {
                let approval = CredentialVault.Approval.scope(name: name, scope: scope)
                let allowed: Bool
                if let approve {
                    allowed = await approve(approval)
                } else if let window = window() {
                    allowed = await CredentialVault.askApproval(approval, in: window)
                } else {
                    throw PageError.unavailable("Settings has no window")
                }
                guard allowed else {
                    await board.reload().value
                    return ["done": false]
                }
                try await Self.off { try vault.setScope(name, scope: scope, by: person, agentsApproved: true) }
            }
            done = true
        }
        await board.reload().value
        return ["done": .bool(done)]
    }

    /// The name of a secret the vault holds.
    private func existing(_ params: JSONValue) throws -> String {
        guard let name = params["name"]?.stringValue, CredentialVault.isValidName(name) else {
            throw PageError.invalidParams(CredentialVaultStrings.invalidName(params["name"]?.stringValue ?? ""))
        }
        guard board.entries[name] != nil else {
            throw PageError(code: "vault.missing", message: CredentialVaultStrings.missing([name]))
        }
        return name
    }

    /// Shows the entry sheet and stores the answer; false when the person cancelled. Add never
    /// replaces: a taken name brings the sheet back (``CredentialVault/enterNew(_:by:event:ask:)``),
    /// and the row's Replace replaces.
    private func enter(_ request: CredentialVault.EntryRequest, person: CredentialVault.Caller) async throws -> Bool {
        guard let window = window() else { throw PageError.unavailable("Settings has no window") }
        let vault = board.vault
        guard request.replaces else {
            do {
                return try await vault.enterNew(request, by: person, event: "set") { await CredentialVault.askForEntry($0, in: window) } != nil
            } catch let failure as CredentialVault.Failure {
                throw Self.pageError(failure)
            }
        }
        guard let answer = await CredentialVault.askForEntry(request, in: window) else { return false }
        _ = try await Self.off {
            try vault.set(answer.name, value: answer.value, scope: answer.scope, note: nil, by: person, event: "replace")
        }
        return true
    }

    /// `body` off the main actor (the Keychain and the index block), its failure as a page error.
    private static func off<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await Task.detached(priority: .userInitiated) { try body() }.value
        } catch let failure as CredentialVault.Failure {
            throw pageError(failure)
        }
    }

    private static func pageError(_ failure: CredentialVault.Failure) -> PageError {
        let error = VaultControl.error(failure)
        return PageError(code: error.code, message: error.message)
    }

    public static let deleteDialogIdentifier = "cmux.dialog.credentialVault.delete"
    static let deleteButton = "delete"

    static func deleteSheet(_ name: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: CredentialVaultStrings.deleteTitle(name), lines: [CredentialVaultStrings.deleteLine],
                       buttons: [.cancel(CredentialVaultStrings.entryCancel),
                                 CmuxDialogButton(id: deleteButton, title: CredentialVaultStrings.deleteButton, role: .destructive)],
                       identifier: deleteDialogIdentifier)
    }

    private static func confirmDelete(_ name: String, in window: NSWindow) async -> Bool {
        let answer = await CmuxDialogCenter.shared.present(deleteSheet(name), in: .window(window))
        return !answer.isDismissal && answer.button == deleteButton
    }
}
