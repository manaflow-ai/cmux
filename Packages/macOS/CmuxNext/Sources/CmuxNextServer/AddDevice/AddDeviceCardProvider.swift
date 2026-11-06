public import AppKit
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Add Device on the server card page (`#/add-device`, webviews/src/pages/server-cards/addDevice;
/// plans/cmux-next/add-device-DESIGN.md): the one entry for every new device. The page derives the
/// way, the footer, the join line's phases and its countdown (`addDevice/model.ts`); Swift keeps
/// only what touches the system, through ``AddDeviceServices``: the CLI runs (`cmux device list`,
/// `cmux machine add|list|doctor`), the clipboard, and the hand-offs to the Add Machine, Add Server
/// and Pair Another Machine cards, so the enroll and the approval each stay one flow.
///
/// - `status` → `{session, open, way, join, invite}`: one session per opening;
/// - `list` → the network's computers not added yet (`{network, available}`), or null;
/// - `mint {name}` → `{line}` or `{failure}`: a single-use join line. The line's text reaches the
///   page to be shown; the provider keeps it for the concealed copy and never logs it;
/// - `joined` → the machine that joined with the shown line (`cmux machine list`, read once), or null;
/// - `doctor` → that machine's checks;
/// - `copyJoinLine` → the shown line, concealed and transient (the page never sends it back);
/// - `copySetupLine {platform}`, `addComputer {address, name}`, `addByName`, `enterCode`,
///   `newCloudMachine`, `installTailscale`, `signIn`, `showMachines`, `pairAnotherMachine`;
/// - stream `changes` → `{kind: "opened" | "closed"}`, and `{kind: "mesh"}` on each mesh change
///   while a line shows (the page reads `joined` once; nothing polls).
///
/// SECURITY: every action and the mint need the person's own click or key in the page
/// (`userGesture`), as the native card's buttons did; reads do not.
@MainActor
public final class AddDeviceCardProvider: WebCard {
    public static let route = "add-device"
    static let statusOp = "cmux.addDevice.status"
    static let listOp = "cmux.addDevice.list"
    static let mintOp = "cmux.addDevice.mint"
    static let joinedOp = "cmux.addDevice.joined"
    static let doctorOp = "cmux.addDevice.doctor"
    static let copyJoinLineOp = "cmux.addDevice.copyJoinLine"
    static let copySetupLineOp = "cmux.addDevice.copySetupLine"
    static let changesStream = "cmux.addDevice.changes"

    public var card: String { Self.route }
    public var prefix: String { "cmux.addDevice." }
    public weak var host: WebCardPanel?

    private let services: AddDeviceServices
    private let panel: @MainActor () -> WebCardPanel?
    private let personOnlyMessage: String
    private(set) var session = 0
    private(set) var isOpen = false
    /// The way the opening asked for (`device.add way=…`), checked by the page.
    private var way: String?
    /// The opening's join calls; nil when the app offers no join (ssh stays first).
    private var join: MachineJoinService?
    /// Signed in: the "Any machine" way hands off to Pair Another Machine.
    private var openInvite: (() -> Void)?
    /// The shown line (its token is inside `line`): kept for the concealed copy only.
    private var shown: JoinLine?
    private var joinedID: String?
    private var mesh: Task<Void, Never>?
    private var listeners: [Int: @MainActor (JSONValue) -> Void] = [:]
    private var nextListener = 0
    #if DEBUG
    /// `debug.add_device {join}`: the page presses Make Line with this name once the card opened
    /// (captures only; the mint then needs no gesture).
    public var debugMintName: String?
    #endif

    /// - Parameters:
    ///   - panel: The server card panel the card shows in (made on first use and kept warm).
    ///   - personOnlyMessage: The refusal of an action asked for without the person's click or key.
    public init(services: AddDeviceServices, panel: @escaping @MainActor () -> WebCardPanel?, personOnlyMessage: String) {
        self.services = services
        self.panel = panel
        self.personOnlyMessage = personOnlyMessage
    }

    // Not an isolated deinit (cx-t7hu): the handle is Sendable and stops from any thread.
    nonisolated deinit {
        mesh?.cancel()
    }

    /// Opens the card over `window`, on `way` when given (`network`, `code`, `newDevice`,
    /// `joinLine`); the page reads the network again.
    public func open(way: String? = nil, over window: NSWindow?) {
        self.way = way
        panel()?.present(card: Self.route, over: window, takeKeys: true)
    }

    public var isShown: Bool { isOpen && host?.isVisible == true && host?.card == Self.route }

    public func close() {
        guard isShown else { return }
        host?.dismiss()
    }

    /// Whether the mesh watch still runs (tests check that close stops it).
    var isWatching: Bool { mesh != nil }

    // MARK: - WebCard

    /// Every opening starts the card over, as the native card's did.
    public func opened(again: Bool) {
        endLine()
        session += 1
        isOpen = true
        join = services.machineJoin()
        openInvite = join == nil ? nil : services.pairAnotherMachine()
        emit("opened")
    }

    /// The card closed: a late mint or read is dropped, the mesh watch stops.
    public func closed() {
        endLine()
        session += 1
        isOpen = false
        way = nil
        emit("closed")
    }

    private func endLine() {
        mesh?.cancel()
        mesh = nil
        shown = nil
        joinedID = nil
    }

    // MARK: - Page ops

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.statusOp:
            return status()
        case Self.listOp:
            guard let listing = await services.list() else { return .null }
            return Self.json(listing)
        case Self.joinedOp:
            return await joined()
        case Self.doctorOp:
            guard let join, let joinedID else { return .array([]) }
            return .array(await join.doctor(joinedID).map(Self.json))
        case Self.mintOp:
            #if DEBUG
            if debugMintName == nil { try requireGesture(context) }
            #else
            try requireGesture(context)
            #endif
            return await mint(params["name"]?.stringValue)
        default:
            try requireGesture(context)
            try act(op, params)
            return .null
        }
    }

    /// One click or key of the card. A hand-off runs, then the panel hides unless the hand-off put
    /// another card in it (Add Machine, Pair Another Machine).
    private func act(_ op: String, _ params: JSONValue) throws {
        switch op {
        case Self.copyJoinLineOp:
            guard let shown else { throw PageError.invalidParams("no line shows") }
            services.copyConcealed(shown.line)
            return
        case Self.copySetupLineOp:
            guard let line = params["platform"]?.stringValue.flatMap({ Self.setupLines[$0] }) else {
                throw PageError.invalidParams("platform is macOrLinux or windows")
            }
            services.copy(line)
            return
        case "cmux.addDevice.installTailscale":
            services.installTailscale()
            return
        case "cmux.addDevice.addComputer":
            guard let address = params["address"]?.stringValue, !address.isEmpty else { throw PageError.invalidParams("address is required") }
            handOff { services.addComputer(address, params["name"]?.stringValue ?? address) }
        case "cmux.addDevice.addByName": handOff(services.addByName)
        case "cmux.addDevice.enterCode": handOff(services.enterCode)
        case "cmux.addDevice.newCloudMachine": handOff(services.newCloudMachine)
        case "cmux.addDevice.signIn": handOff(services.signIn)
        case "cmux.addDevice.showMachines": handOff(services.showMachines)
        case "cmux.addDevice.pairAnotherMachine":
            guard let openInvite else { throw PageError.invalidParams("Pair Another Machine is not offered") }
            handOff(openInvite)
        default:
            throw PageError.unknownOp(op)
        }
    }

    private func handOff(_ run: () -> Void) {
        let mine = session
        run()
        // Another card took the panel (its opening closed this one), else the panel hides.
        if mine == session { close() }
    }

    private func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: personOnlyMessage) }
    }

    /// Mints a new line; any earlier one is dropped (a line is never shown twice).
    private func mint(_ name: String?) async -> JSONValue {
        guard let join else { return ["failure": "unavailable"] }
        endLine()
        let mine = session
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await join.mint(trimmed?.isEmpty == false ? trimmed : nil)
        guard mine == session else { return ["failure": "failed"] }
        switch result {
        case let .success(line):
            shown = line
            startMesh(join, mine)
            return ["line": [
                "line": .string(line.line), "joinTokenId": .string(line.joinTokenId),
                "expiresAt": JSONValue(Int((line.expiresAt.timeIntervalSince1970 * 1000).rounded())),
            ]]
        case let .failure(failure):
            return ["failure": .string(Self.wire(failure))]
        }
    }

    /// Reads the machine list once; the row carrying the shown line's `joinTokenId` is the joined one.
    private func joined() async -> JSONValue {
        guard let join, let line = shown else { return .null }
        let mine = session
        guard let rows = await join.list(), mine == session, shown == line,
              let row = rows.first(where: { $0.joinTokenId == line.joinTokenId }) else { return .null }
        joinedID = row.id
        mesh?.cancel()
        mesh = nil
        return ["id": .string(row.id), "name": .string(row.name)]
    }

    private func startMesh(_ join: MachineJoinService, _ mine: Int) {
        let changes = join.meshChanges()
        // task-owner: the mesh watch; ends with the line (endLine()), on the flip, or when the stream ends.
        mesh = Task { [weak self] in
            for await _ in changes {
                guard let self, self.session == mine else { return }
                self.emit("mesh")
            }
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changesStream else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        return PageSubscription { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    private func emit(_ kind: String) {
        for listener in listeners.values { listener(["kind": .string(kind)]) }
    }

    // MARK: - JSON

    func status() -> JSONValue {
        var reply: [String: JSONValue] = [
            "session": JSONValue(session), "open": .bool(isOpen), "way": way.map(JSONValue.string) ?? .null,
            "join": .bool(join != nil), "invite": .bool(openInvite != nil),
        ]
        #if DEBUG
        if let debugMintName { reply["mintName"] = .string(debugMintName) }
        #endif
        return .object(reply)
    }

    /// The line a new computer runs: install cmux, then show its pairing code and words.
    static let setupLines = [
        "macOrLinux": "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/cmux server pair",
        "windows": "irm https://cmux.com/tui/install-static.ps1 | iex; cmux server pair",
    ]

    static func wire(_ failure: JoinLineFailure) -> String {
        switch failure {
        case .signedOut: "signedOut"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }

    static func json(_ listing: DeviceListing) -> JSONValue {
        [
            "network": ["kind": .string(listing.network.kind), "up": .bool(listing.network.up),
                        "detail": listing.network.detail.map(JSONValue.string) ?? .null],
            "available": .array(listing.available.map { computer in
                ["name": .string(computer.name), "address": .string(computer.address), "os": .string(computer.os),
                 "mine": .bool(computer.mine), "fromSSHConfig": .bool(computer.fromSSHConfig)]
            }),
        ]
    }

    static func json(_ check: HostStepResult) -> JSONValue {
        ["step": .string(check.step.rawValue), "title": .string(AddMachineStrings.step(check.step)),
         "state": .string(check.state.rawValue), "detail": .string(check.detail),
         "fix": check.fix.map(JSONValue.string) ?? .null]
    }
}
