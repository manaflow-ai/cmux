import Foundation
import Observation

/// The cmux vault on this phone (cmuxterm-hq docs/design/e2e-vault.md): the person's secrets and env
/// values, end to end encrypted, with this phone one of their enrolled devices. Every decision is
/// Rust's (`cmux-mobile-link-ffi` `vault.rs` over `cmux-vault-e2e`); the app's ``VaultService``
/// is that client. Answers are names, scopes, devices and codes: a value goes in and never comes out.
public protocol VaultService: Sendable {
    /// The JSON of the vault's status (``VaultStatus``).
    func status() async throws -> String
    func turnOn() async throws -> String
    func approve(code: String) async throws
    func removeDevice(id: String) async throws
    func set(name: String, scope: String, value: String) async throws
    func remove(name: String, scope: String) async throws
    /// The JSON of ``VaultImportPreview``: names only.
    func importPreview(envText: String, scope: String) async throws -> String
    func importNames(envText: String, names: [String], scope: String) async throws -> Int
    /// The JSON of ``VaultSyncAnswer``.
    func sync() async throws -> String
    /// The scope's wire text, or nil when `target` is not one the vault takes.
    func scope(kind: VaultScopeKind, target: String) -> String?
    func isValidName(_ name: String) -> Bool
}

/// Why a vault call failed, in words free of any value.
public enum VaultFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case unreachable
    case refused(code: String, message: String)

    public var description: String {
        switch self {
        case .unreachable: String(localized: "Couldn't reach cmux Cloud. Check your connection.")
        case let .refused(_, message): message
        }
    }
}

public enum VaultScopeKind: String, CaseIterable, Identifiable, Sendable {
    case all, repo, machine
    public var id: String { rawValue }
}

/// The vault as this phone sees it (`cmux_vault_e2e::client::Status`).
public struct VaultStatus: Decodable, Equatable, Sendable {
    /// `off`, `pending`, `active` or `not_enrolled`.
    public var state: String
    public var epoch: UInt64
    public var deviceId: String?
    public var safetyCode: String?
    public var devices: [VaultDevice]
    public var items: [VaultItem]
}

public struct VaultDevice: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    /// `active` or `pending`.
    public var state: String
    public var safetyCode: String
    public var thisDevice: Bool
}

/// A kept name: never its value.
public struct VaultItem: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var scope: String
    public var scopeLabel: String
    public var revision: UInt64
    public var masked: String
}

public struct VaultImportPreview: Decodable, Equatable, Sendable {
    public struct Row: Decodable, Equatable, Identifiable, Sendable {
        public var name: String
        public var line: Int
        public var keepable: Bool
        public var alreadyKept: Bool
        public var id: String { name }
    }

    public var rows: [Row]
    public var skippedLines: [Int]
}

public struct VaultSyncAnswer: Decodable, Equatable, Sendable {
    public struct Machine: Decodable, Equatable, Sendable {
        public var id: String
        public var outcome: String
    }

    /// `off`, `pending`, `busy` or `done`.
    public var outcome: String
    public var machines: [Machine]
}

/// Settings → Cloud → Vault.
@MainActor
@Observable
public final class VaultModel {
    public enum Phase: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    public private(set) var phase: Phase = .loading
    /// The status read failed and nothing is shown yet: ``VaultScreen`` reads it again on its own (AutoRetry).
    public var isLoadFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
    public private(set) var status: VaultStatus?
    /// A call is running: actions wait.
    public private(set) var busy = false
    /// Why the last action failed; the page shows it once.
    public var failure: String?
    @ObservationIgnored let service: any VaultService

    public init(service: any VaultService) {
        self.service = service
    }

    public var state: String { status?.state ?? "off" }
    public var items: [VaultItem] { status?.items ?? [] }
    /// This phone first, then active devices, then those waiting.
    public var devices: [VaultDevice] {
        (status?.devices ?? []).sorted { a, b in
            if a.thisDevice != b.thisDevice { return a.thisDevice }
            if a.state != b.state { return a.state == "active" }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    public func load() async {
        do {
            status = try Self.decode(VaultStatus.self, try await service.status())
            phase = .loaded
        } catch is CancellationError {
        } catch {
            if status == nil { phase = .failed(Self.message(error)) } else { failure = Self.message(error) }
        }
    }

    public func turnOn() async {
        await act { model in
            model.status = try Self.decode(VaultStatus.self, try await model.service.turnOn())
        }
    }

    /// Approve a waiting device after the person compared its code with the one it shows.
    public func approve(_ device: VaultDevice) async {
        await act { try await $0.service.approve(code: device.safetyCode) }
    }

    public func remove(_ device: VaultDevice) async {
        await act { try await $0.service.removeDevice(id: device.id) }
    }

    /// Keep `value` for `name` in `scope` (wire text). Answers whether it was kept.
    @discardableResult
    public func set(name: String, scope: String, value: String) async -> Bool {
        await act(syncs: true) { try await $0.service.set(name: name, scope: scope, value: value) }
    }

    public func remove(_ item: VaultItem) async {
        await act(syncs: true) { try await $0.service.remove(name: item.name, scope: item.scope) }
    }

    /// The names `envText` sets, for the person to pick from.
    public func preview(envText: String, scope: String) async -> VaultImportPreview? {
        do {
            return try Self.decode(VaultImportPreview.self, try await service.importPreview(envText: envText, scope: scope))
        } catch {
            failure = Self.message(error)
            return nil
        }
    }

    @discardableResult
    public func importNames(envText: String, names: [String], scope: String) async -> Bool {
        await act(syncs: true) { _ = try await $0.service.importNames(envText: envText, names: names, scope: scope) }
    }

    public func scope(kind: VaultScopeKind, target: String) -> String? { service.scope(kind: kind, target: target) }
    public func isValidName(_ name: String) -> Bool { service.isValidName(name) }

    /// Runs one change, then reads the vault again; a change to the values also seals them to the
    /// person's machines, off the main thread, without holding the page.
    @discardableResult
    private func act(syncs: Bool = false, _ work: @MainActor (VaultModel) async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await work(self)
        } catch is CancellationError {
            return false
        } catch {
            failure = Self.message(error)
            await load()
            return false
        }
        await load()
        if syncs { VaultTriggers.changed() }
        return true
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(json.utf8)) } catch {
            throw VaultFailure.refused(code: "vault.bad_answer", message: String(localized: "cmux Cloud answered something the phone can't read."))
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? VaultFailure)?.description ?? VaultFailure.unreachable.description
    }
}

/// When the vault seals values to the person's machines: after a change here, after this phone
/// starts or makes a Cloud machine, and when the app comes to the foreground. The app sets
/// ``run`` to its bounded, off-main sync (`VaultSync` in CmuxMobileLive); nil does nothing.
@MainActor
public enum VaultTriggers {
    public enum Reason: String, Sendable {
        case changed, machineStarted, foreground
    }

    public static var run: ((Reason) -> Void)?

    public static func changed() { run?(.changed) }
    public static func machineStarted() { run?(.machineStarted) }
    public static func foreground() { run?(.foreground) }
}

#if DEBUG
/// Fixed vaults for the gallery's screenshots (`-cmux-mobile-recovery-gallery vault-off|vault-pending|vault-on`).
public struct GalleryVaultService: VaultService {
    let json: String

    public init(state: String) {
        let phone = #"{"id":"dev_phone","kind":"iphone","label":"Leo's iPhone","state":"STATE","safetyCode":"4821 0937","thisDevice":true}"#
        let mac = #"{"id":"dev_mac","kind":"mac","label":"Leo's MacBook Pro","state":"active","safetyCode":"1650 2284","thisDevice":false}"#
        let ipad = #"{"id":"dev_cli","kind":"cli","label":"build-box (cmux CLI)","state":"pending","safetyCode":"7703 1149","thisDevice":false}"#
        let items = #"""
        [{"id":"i1","name":"ANTHROPIC_API_KEY","scope":"*","scopeLabel":"every machine","revision":1,"updatedAt":1,"masked":"••••••••"},
         {"id":"i2","name":"DATABASE_URL","scope":"repo:manaflow-ai/cmux","scopeLabel":"repo manaflow-ai/cmux","revision":1,"updatedAt":1,"masked":"••••••••"},
         {"id":"i3","name":"GITHUB_TOKEN","scope":"*","scopeLabel":"every machine","revision":1,"updatedAt":1,"masked":"••••••••"},
         {"id":"i4","name":"STRIPE_SECRET_KEY","scope":"machine:vm_k3x9q2m7p1z8w4n6t5r0","scopeLabel":"machine vm_k3x9q2m7p1z8w4n6t5r0","revision":1,"updatedAt":1,"masked":"••••••••"}]
        """#
        switch state {
        case "pending":
            json = #"{"vault":"personal","state":"pending","epoch":1,"deviceId":"dev_phone","safetyCode":"4821 0937","devices":[\#(mac),\#(phone.replacingOccurrences(of: "STATE", with: "pending"))],"items":[]}"#
        case "on":
            json = #"{"vault":"personal","state":"active","epoch":2,"deviceId":"dev_phone","safetyCode":"4821 0937","devices":[\#(mac),\#(phone.replacingOccurrences(of: "STATE", with: "active")),\#(ipad)],"items":\#(items)}"#
        default:
            json = #"{"vault":"personal","state":"off","epoch":0,"deviceId":null,"safetyCode":null,"devices":[],"items":[]}"#
        }
    }

    public func status() async throws -> String { json }
    public func turnOn() async throws -> String { json }
    public func approve(code: String) async throws {}
    public func removeDevice(id: String) async throws {}
    public func set(name: String, scope: String, value: String) async throws {}
    public func remove(name: String, scope: String) async throws {}
    public func importPreview(envText: String, scope: String) async throws -> String { #"{"rows":[],"skippedLines":[]}"# }
    public func importNames(envText: String, names: [String], scope: String) async throws -> Int { names.count }
    public func sync() async throws -> String { #"{"outcome":"done","machines":[]}"# }
    public func scope(kind: VaultScopeKind, target: String) -> String? {
        switch kind {
        case .all: "*"
        case .repo: target.contains("/") ? "repo:\(target.lowercased())" : nil
        case .machine: target.hasPrefix("vm_") ? "machine:\(target)" : nil
        }
    }
    public func isValidName(_ name: String) -> Bool { !name.isEmpty }
}

extension VaultModel {
    public static func gallery(state: String) -> VaultModel {
        VaultModel(service: GalleryVaultService(state: state))
    }
}
#endif
