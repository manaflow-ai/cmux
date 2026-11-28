#if canImport(CmuxMobileLinkFFI)
import CmuxMobileChief
import CmuxMobileLinkFFI
import Foundation
import OSLog

// The cmux vault's Rust client (`cmux-mobile-link-ffi` `vault.rs` over `cmux-vault-e2e`) as the
// phone's ``VaultService``. Rust decides every request and does every seal; Swift sends each request
// over the account's own Cloud path (``AccountCloud/vault(_:_:device:body:timeout:)``, which sends
// nothing outside `/v1/cloud/vault`) and keeps this phone's device key in the Keychain. No value is
// logged: the log lines here name reasons and outcomes only.

private let log = Logger(subsystem: "dev.cmux.mobile", category: "vault")

/// The app's HTTP path, as the Rust client asks for it.
final class VaultCloudHTTP: VaultHttp, @unchecked Sendable {
    private let account: @Sendable () async -> AccountCloud?

    init(account: @escaping @Sendable () async -> AccountCloud?) {
        self.account = account
    }

    func send(request: VaultHttpRequest) async throws -> VaultHttpReply {
        guard let account = await account() else { throw VaultBridgeError.Failed(message: "not signed in") }
        do {
            let reply = try await account.vault(request.method, request.path, device: request.device,
                                                body: request.body.map { Data($0.utf8) },
                                                timeout: TimeInterval(request.timeoutMs) / 1000)
            return VaultHttpReply(status: UInt16(clamping: reply.status), body: String(decoding: reply.body, as: UTF8.self))
        } catch {
            throw VaultBridgeError.Failed(message: "no answer")
        }
    }
}

/// This phone's vault device record: one generic-password item, this device only, readable after
/// the first unlock (``KeychainSecretStore``), under the account's own Keychain account name.
final class VaultKeychain: VaultKeyStore, @unchecked Sendable {
    static let service = "cmux-vault-device"
    private let store: any DeviceSecretStore
    private let account: String

    init(account: String, store: any DeviceSecretStore = KeychainSecretStore()) {
        self.account = account
        self.store = store
    }

    func load() throws -> Data? {
        do { return try store.read(service: Self.service, account: account) } catch {
            throw VaultBridgeError.Failed(message: "keychain")
        }
    }

    func save(record: Data) throws {
        do { try store.write(record, service: Self.service, account: account) } catch {
            throw VaultBridgeError.Failed(message: "keychain")
        }
    }
}

private func vaultFailure(_ error: any Error) -> VaultFailure {
    guard let error = error as? VaultError else { return .unreachable }
    switch error {
    case .Unreachable: return .unreachable
    case let .Refused(code, message): return .refused(code: code, message: message)
    }
}

/// The account's vault through the Rust client.
struct FFIVaultService: VaultService {
    let vault: PhoneVault

    init(vault: PhoneVault) {
        self.vault = vault
    }

    func status() async throws -> String {
        do { return try await vault.status() } catch { throw vaultFailure(error) }
    }

    func turnOn() async throws -> String {
        do { return try await vault.turnOn() } catch { throw vaultFailure(error) }
    }

    func approve(code: String) async throws {
        do { _ = try await vault.approve(code: code) } catch { throw vaultFailure(error) }
    }

    func removeDevice(id: String) async throws {
        do { _ = try await vault.removeDevice(deviceId: id) } catch { throw vaultFailure(error) }
    }

    func set(name: String, scope: String, value: String) async throws {
        do { _ = try await vault.set(name: name, scope: scope, value: value) } catch { throw vaultFailure(error) }
    }

    func remove(name: String, scope: String) async throws {
        do { _ = try await vault.remove(name: name, scope: scope) } catch { throw vaultFailure(error) }
    }

    func importPreview(envText: String, scope: String) async throws -> String {
        do { return try await vault.importPreview(envText: envText, scope: scope) } catch { throw vaultFailure(error) }
    }

    func importNames(envText: String, names: [String], scope: String) async throws -> Int {
        do { return Int(try await vault.importNames(envText: envText, names: names, scope: scope)) } catch { throw vaultFailure(error) }
    }

    func sync() async throws -> String {
        do { return try await vault.sync() } catch { throw vaultFailure(error) }
    }

    func scope(kind: VaultScopeKind, target: String) -> String? {
        vaultScope(kind: kind.rawValue, target: target)
    }

    func isValidName(_ name: String) -> Bool {
        vaultValidName(name: name)
    }
}

/// One Rust vault per signed-in account (its Keychain account name), and the sync the app runs
/// after a change, after this phone starts a Cloud machine, and on foreground.
@MainActor
public final class VaultSync {
    public static let shared = VaultSync()

    private var current: (key: String, vault: PhoneVault)?
    private var running: Task<Void, Never>?
    /// A trigger came while a sync ran: one more runs after it, so a change is never left unsealed.
    private var again: VaultTriggers.Reason?

    /// The signed-in account's vault, made once per account; nil when signed out.
    func vault() -> PhoneVault? {
        guard let key = ChiefSources.shared.vaultKeyAccount else { return nil }
        if let current, current.key == key { return current.vault }
        let vault = PhoneVault(http: VaultCloudHTTP(account: { await ChiefSources.shared.account }),
                               store: VaultKeychain(account: key), label: ChiefSources.vaultDeviceLabel)
        current = (key, vault)
        return vault
    }

    /// Points ``VaultTriggers`` at this sync. Called once at launch.
    public func install() {
        VaultTriggers.run = { [weak self] reason in self?.run(reason) }
    }

    /// Seals the person's machines what they should hold, off the main thread: Rust sends nothing
    /// when this phone holds no vault key, runs one sync at a time and stops at its time budget.
    public func run(_ reason: VaultTriggers.Reason) {
        guard let vault = vault() else { return }
        guard running == nil else {
            again = reason
            return
        }
        running = Task.detached(priority: .utility) { [weak self] in
            let outcome: String
            do {
                let answer = try JSONDecoder().decode(VaultSyncAnswer.self, from: Data(try await vault.sync().utf8))
                let delivered = answer.machines.filter { $0.outcome == "delivered" }.count
                outcome = "\(answer.outcome) machines=\(answer.machines.count) delivered=\(delivered)"
            } catch {
                outcome = "failed"
            }
            log.info("vault sync (\(reason.rawValue, privacy: .public)): \(outcome, privacy: .public)")
            await MainActor.run {
                guard let self else { return }
                self.running = nil
                if let next = self.again {
                    self.again = nil
                    self.run(next)
                }
            }
        }
    }
}

extension VaultModel {
    /// The signed-in account's vault, through the Rust client.
    public static func live() -> VaultModel? {
        VaultSync.shared.vault().map { VaultModel(service: FFIVaultService(vault: $0)) }
    }
}
#endif
