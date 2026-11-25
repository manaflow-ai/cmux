public import Foundation
import CmuxNextCompat
import Observation
import os
import Security

/// "Computer use can act as me": an explicit, revocable grant on the person gate
/// (``AgentPanePersonInput``). Off by default. While it is on, a key press or click another process
/// posts in an agent pane (cua-driver, CGEventPost) counts as the person's for Send and Retry
/// (`session/prompt`) and Approve (`_acpmux/queue_approve`), ``covers``, and for nothing wider: a
/// permission answer, a mode, a trust grant, a folder or a new chat on another machine still needs
/// the person's own input. The rules are cmux-tui `cmux_agent_pane_policy::act_as_me` (its tests are the
/// gate's tests; `tests/swift.rs` checks ``covers`` against `policy.json` `act_as_me_covers`).
///
/// Who turns it on:
/// - the person's own click on Allow in the consent card (``AgentPaneActAsMeCard``), read from the
///   click itself by the app's strict check (``PersonInputCheck``: HID input only). Only the card can
///   make the ``PersonClick`` that ``turnOn(_:)`` takes;
/// - a forced `ComputerUseActsAsPerson` in the managed domain (``setManaged(_:)``), which only an
///   administrator's profile installs. A value that is not forced (`defaults write`) never counts.
/// No RPC, CLI, MCP, page frame or config key reaches either. The person's grant is kept in this
/// app's data-protection Keychain (``Store/keychain(service:)``), which no other process can write; a
/// DEV build without a Team ID keeps it for this launch only.
///
/// ``turnOff()`` needs no proof (one click, from the indicator or the card), and holds a managed grant
/// off until the app starts again. Every let-through is logged with the driver's identity
/// (``recordLetThrough(method:driver:)``).
@MainActor @Observable public final class AgentPaneActAsMe {
    /// The methods a posted gesture may grant while the grant is on (policy.json `act_as_me_covers`).
    public nonisolated static let covers: Set<String> = [
        "session/prompt",
        "_acpmux/queue_approve",
    ]

    /// The managed policy key (docs/mdm).
    public nonisolated static let managedKey = "ComputerUseActsAsPerson"

    public nonisolated enum Holder: String, Sendable {
        case person
        case managed
    }

    /// The process that posted the input a let-through used.
    public nonisolated struct Driver: Sendable, Equatable {
        public var pid: pid_t?
        public var path: String?
        public var bundleID: String?
        public var cuaSession: String?

        public init(pid: pid_t?, path: String?, bundleID: String? = nil, cuaSession: String? = nil) {
            (self.pid, self.path, self.bundleID, self.cuaSession) = (pid, path, bundleID, cuaSession)
        }
    }

    /// One let-through, as cmux-tui's `let_through_record` shapes it.
    public nonisolated struct LetThrough: Sendable, Equatable {
        public let method: String
        public let holder: Holder
        public let driver: Driver
    }

    /// The person's own click on the card's Allow. Only ``AgentPaneActAsMeCard`` makes one, from the
    /// click itself (``AgentPaneActAsMeCard/takePersonClick(on:up:)``); nothing outside this module can.
    public nonisolated struct PersonClick: Sendable {
        init() {}
    }

    /// Where the person's grant is kept. Writes run off main and store the latest value under a lock, so
    /// two quick changes never land out of order.
    public nonisolated final class Store: Sendable {
        let read: @Sendable () -> Bool
        private let write: @Sendable (Bool) -> Void
        // lock carve-out: the latest grant, set on main, written off main by each persist task
        private let latest = Mutex(false)

        init(read: @escaping @Sendable () -> Bool, write: @escaping @Sendable (Bool) -> Void) {
            (self.read, self.write) = (read, write)
        }

        /// The value the next write stores.
        func set(_ on: Bool) { latest.withLock { $0 = on } }

        /// Stores the latest value.
        func flush() { latest.withLock { write($0) } }

        /// This launch only (tests, a DEV build without a Team ID).
        public static func memory() -> Store {
            let value = Mutex(false)
            return Store(read: { value.withLock { $0 } }, write: { on in value.withLock { $0 = on } })
        }

        /// A generic password in this app's data-protection Keychain under `service`: only this app's
        /// access group reads or writes it, so `security`, `defaults write` or a file an agent writes
        /// cannot turn it on.
        public static func keychain(service: String) -> Store {
            @Sendable func query() -> [String: Any] {
                [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                 kSecAttrAccount as String: "act-as-me", kSecAttrSynchronizable as String: false,
                 kSecUseDataProtectionKeychain as String: true]
            }
            return Store(read: {
                var read = query()
                read[kSecReturnData as String] = true
                read[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: CFTypeRef?
                return SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess && (out as? Data) == Data("on".utf8)
            }, write: { on in
                SecItemDelete(query() as CFDictionary)
                guard on else { return }
                var add = query()
                add[kSecValueData as String] = Data("on".utf8)
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            })
        }
    }

    private var person = false
    private var managed = false
    /// The person turned a managed grant off for this run of the app.
    private var managedHeldOff = false
    /// Counts ``turnOff()`` calls: a posted gesture or a ticket it reserved carries the count it was made
    /// under, and is void once the grant was turned off after it, even when the grant is on again.
    public private(set) var revocations = 0
    /// The latest let-throughs, newest last (at most ``keptLetThroughs``).
    public private(set) var letThroughs: [LetThrough] = []
    static let keptLetThroughs = 64
    @ObservationIgnored private let store: Store
    @ObservationIgnored nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.act-as-me")

    public init(store: Store = .memory()) {
        self.store = store
    }

    /// Reads the person's stored grant (off main: a Keychain read).
    /// A Turn Off pressed while the read runs wins: the stored grant does not turn it back on.
    public func load() async {
        let before = revocations
        if await Self.read(store), revocations == before { person = true }
    }

    public var holder: Holder? {
        if person { return .person }
        if managed, !managedHeldOff { return .managed }
        return nil
    }

    public var isOn: Bool { holder != nil }

    /// Turns the grant on: only from the person's own click on the card.
    public func turnOn(_ click: PersonClick) {
        _ = click
        person = true
        managedHeldOff = false
        Self.logger.notice("act-as-me turned on by the person's click")
        persist(true)
    }

    /// Whether the managed domain forces the grant on (read again on every settings load).
    public func setManaged(_ forced: Bool) {
        guard managed != forced else { return }
        managed = forced
        Self.logger.notice("act-as-me managed=\(forced, privacy: .public)")
    }

    /// Turns the grant off, from any press: revoking needs no proof.
    public func turnOff() {
        person = false
        revocations += 1
        // Held off even before the launch's managed read lands, so a forced value read later cannot undo it.
        managedHeldOff = true
        Self.logger.notice("act-as-me turned off")
        persist(false)
    }

    /// The launch read of the stored grant and the managed profile (``start(check:)``).
    @ObservationIgnored var following: Task<Void, Never>?
    /// Shows the consent card (the app sets it); nil (tests) shows none.
    @ObservationIgnored public var ask: (@MainActor () -> Void)?
    /// The card asked once in this run of the app: an agent's refused sends never show it again.
    public private(set) var asked = false

    /// Asks the person once per run of the app, from the consent card, after a Send, Retry or Approve that
    /// another process's input was behind was refused. Asking grants nothing.
    public func askOnce() {
        guard !asked, !isOn, let ask else { return }
        asked = true
        ask()
    }

    /// Whether a posted gesture may grant a frame of `method` now.
    public func lets(_ method: String) -> Holder? {
        Self.covers.contains(method) ? holder : nil
    }

    /// Logs a frame the grant let through, with the driver's identity. The bundle id is read off main.
    public func recordLetThrough(method: String, holder: Holder, driver: Driver) {
        letThroughs.append(LetThrough(method: method, holder: holder, driver: driver))
        if letThroughs.count > Self.keptLetThroughs { letThroughs.removeFirst(letThroughs.count - Self.keptLetThroughs) }
        // task-owner: one log line per let-through; reads the driver's Info.plist off main and ends
        Task { await Self.log(method: method, holder: holder, driver: driver) }
    }

    @concurrent private static func log(method: String, holder: Holder, driver: Driver) async {
        var full = driver
        if full.bundleID == nil, let path = driver.path { full.bundleID = bundleID(executable: path) }
        logger.notice("""
            act_as_me.let_through method=\(method, privacy: .public) holder=\(holder.rawValue, privacy: .public) \
            pid=\(full.pid.map(String.init) ?? "null", privacy: .public) path=\(full.path ?? "null", privacy: .public) \
            bundleId=\(full.bundleID ?? "null", privacy: .public) cuaSession=\(full.cuaSession ?? "null", privacy: .public)
            """)
    }

    /// The stored grant (a Keychain read, off main).
    @concurrent private static func read(_ store: Store) async -> Bool { store.read() }

    /// Stores the latest grant (a Keychain write, off main).
    @concurrent private static func write(_ store: Store) async { store.flush() }

    /// The bundle id of the app whose executable is at `path` (its enclosing `.app`), nil when none.
    nonisolated static func bundleID(executable path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
    }

    private func persist(_ on: Bool) {
        let store = store
        store.set(on)
        // task-owner: one Keychain write per change, ends on its own
        Task { await Self.write(store) }
    }
}
