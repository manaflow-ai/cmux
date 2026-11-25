import CmuxMobileDesign
import Foundation
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// `GET /v1/me/agent-call` (PROTOCOL.md "Agent calls"): the person's phone-call settings, kept
/// by the service, which places the calls itself, so they arrive with cmux closed or the iPhone
/// locked.
public struct AgentCallState: Equatable, Sendable, Decodable {
    public struct Entry: Equatable, Sendable, Decodable, Identifiable {
        /// Milliseconds since 1970.
        public var at: Double
        /// A trigger's raw value, `test` or `verify`.
        public var trigger: String
        /// `call`, `debounced` or `failed` (the service keeps no record of ignored events). Newest first.
        public var decision: String
        public var reason: String?
        public var id: String { "\(at)-\(trigger)-\(decision)" }

        public init(at: Double, trigger: String, decision: String, reason: String? = nil) {
            self.at = at
            self.trigger = trigger
            self.decision = decision
            self.reason = reason
        }
    }

    /// Whether this service has a phone provider (Twilio) set up.
    public var configured: Bool
    /// `melotts` (MeloTTS on Workers AI) or `twilio-say` (Twilio's own voice).
    public var voice: String
    /// The cmux number the calls come from.
    public var from: String?
    public var enabled: Bool
    public var triggers: [String]
    /// The verified number, masked (`+14••• ••0100`).
    public var number: String?
    /// The number a code call went to, masked, until it is confirmed.
    public var pendingNumber: String?
    /// Milliseconds since 1970.
    public var lastCallAt: Double?
    public var log: [Entry]

    public init(configured: Bool, voice: String = "melotts", from: String? = nil, enabled: Bool = false,
                triggers: [String] = AgentCallTrigger.allCases.map(\.rawValue), number: String? = nil,
                pendingNumber: String? = nil, lastCallAt: Double? = nil, log: [Entry] = []) {
        self.configured = configured
        self.voice = voice
        self.from = from
        self.enabled = enabled
        self.triggers = triggers
        self.number = number
        self.pendingNumber = pendingNumber
        self.lastCallAt = lastCallAt
        self.log = log
    }

    /// Seconds until the next call may go out (the same 30 second window as Agent Alarms), nil when one may now.
    public func debounceRemaining(now: Date) -> TimeInterval? {
        guard let lastCallAt else { return nil }
        let left = lastCallAt / 1000 + AgentCallTrigger.debounce - now.timeIntervalSince1970
        return left > 0 ? left : nil
    }
}

/// What can call: the same needs-you events as Agent Alarms, minus "Mac stopped responding",
/// which only this iPhone can notice.
public enum AgentCallTrigger: String, CaseIterable, Identifiable, Sendable {
    case permission, question, needsInput, agentFailed

    /// At most one call in any 30 seconds, whatever the trigger.
    public static let debounce: TimeInterval = 30

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .permission: String(localized: "Permission requests")
        case .question: String(localized: "Questions")
        case .needsInput: String(localized: "Waiting in a terminal")
        case .agentFailed: String(localized: "Agent stopped with an error")
        }
    }

    var symbol: String {
        switch self {
        case .permission: "hand.raised"
        case .question: "questionmark.bubble"
        case .needsInput: "terminal"
        case .agentFailed: "exclamationmark.octagon"
        }
    }

    /// What the call says (the service's `callScript`, in src/agent-call.ts).
    func script(agent: String, mac: String) -> String {
        let what = switch self {
        case .permission: "\(agent) on \(mac) needs your permission."
        case .question: "\(agent) on \(mac) has a question for you."
        case .needsInput: "\(agent) on \(mac) is waiting for you in its terminal."
        case .agentFailed: "\(agent) on \(mac) stopped and needs you."
        }
        return "Hi, this is cmux. \(what) Open cmux to answer."
    }
}

/// The service's refusal (`{"error":{"code","message"}}`).
public struct AgentCallFailure: Error, Equatable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Settings → Notifications → Phone Calls' service: the live one is `LiveDeviceDirectory`.
@MainActor
public protocol AgentCallService: AnyObject {
    func agentCall() async throws -> AgentCallState
    func setAgentCall(enabled: Bool?, triggers: [String]?, clearNumber: Bool) async throws -> AgentCallState
    /// Places the code call; returns the masked number it calls.
    func verifyAgentCall(number: String) async throws -> String
    func confirmAgentCall(code: String) async throws -> AgentCallState
    /// Places a test call; returns the masked number it calls.
    func testAgentCall() async throws -> String
}

/// Settings → Notifications → Phone Calls: cmux's number calls the person and reads out what
/// needs them, for the same events as Agent Alarms and with the same 30 second window. The
/// service places the call when the Mac reports the event, so it rings with cmux closed.
struct AgentCallsPage: View {
    let service: (any AgentCallService)?
    @State private var state: AgentCallState?
    @State private var loadFailed = false
    @State private var number = ""
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var changingNumber = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if service == nil {
                Section {
                    Text("Sign in to have cmux call you.")
                        .foregroundStyle(theme.colors.label2)
                        .accessibilityIdentifier("settings.agentCalls.signedOut")
                }
            } else if let state {
                content(state)
            } else if loadFailed {
                Section {
                    Text("Phone call settings didn’t load.")
                        .foregroundStyle(theme.colors.label2)
                    Button("Try Again") { Task { await load() } }
                        .accessibilityIdentifier("settings.agentCalls.retry")
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading…").foregroundStyle(theme.colors.label2)
                    }
                    .accessibilityIdentifier("settings.agentCalls.loading")
                }
            }
        }
        .settingsPage("Phone Calls")
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    @ViewBuilder private func content(_ state: AgentCallState) -> some View {
        Section {
            Toggle(isOn: Binding(get: { state.enabled }, set: { on in Task { await update(enabled: on) } })) {
                SettingsLabel("Phone Calls", symbol: "phone.arrow.down.left")
            }
            .disabled(!state.configured || state.number == nil || working)
            .accessibilityIdentifier("settings.agentCalls.enabled")
        } footer: {
            Text(topFooter(state))
        }
        if state.configured {
            numberSection(state)
            Section {
                ForEach(AgentCallTrigger.allCases) { trigger in
                    Toggle(isOn: Binding(get: { state.triggers.contains(trigger.rawValue) },
                                         set: { on in Task { await setTrigger(trigger, on: on) } })) {
                        SettingsLabel(verbatim: trigger.title, symbol: trigger.symbol)
                    }
                    .accessibilityIdentifier("settings.agentCalls.trigger.\(trigger.rawValue)")
                }
            } header: {
                Text("Call for")
            }
            .disabled(!state.enabled || working)
            .opacity(state.enabled ? 1 : 0.4)
            Section {
                Button {
                    Task { await test() }
                } label: {
                    SettingsLabel("Test Call", symbol: "phone.badge.waveform")
                }
                .disabled(state.number == nil || working)
                .accessibilityIdentifier("settings.agentCalls.test")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SettingsLabel("Next call", symbol: "timer", value: nextCall(state, at: context.date))
                        .accessibilityIdentifier("settings.agentCalls.debounce")
                }
            } footer: {
                Text("At most one call in any 30 seconds, shared by every Mac. An event that comes sooner still sends its notification and its alarm.")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(AgentCallTrigger.permission.script(agent: "Claude Code", mac: "Mac mini"))”")
                    Text(voiceLine(state))
                        .font(.footnote)
                        .foregroundStyle(theme.colors.label2)
                }
                .accessibilityIdentifier("settings.agentCalls.sample")
            } header: {
                Text("What you hear")
            }
            Section {
                if state.log.isEmpty {
                    Text("No calls yet.")
                        .foregroundStyle(theme.colors.label2)
                        .accessibilityIdentifier("settings.agentCalls.recent.empty")
                } else {
                    ForEach(state.log) { entry in
                        CallRow(entry: entry)
                    }
                }
            } header: {
                Text("Recent")
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your Macs report each event to the cmux service, which places the call. It rings with cmux closed, swiped away or the iPhone locked.")
                Text("No event, no call: a Mac that is asleep or has no network can’t report one.")
            }
            .font(.footnote)
            .foregroundStyle(theme.colors.label2)
            .accessibilityIdentifier("settings.agentCalls.howItWorks")
        } header: {
            Text("When cmux isn’t open")
        }
    }

    @ViewBuilder private func numberSection(_ state: AgentCallState) -> some View {
        Section {
            if let saved = state.number, !changingNumber, state.pendingNumber == nil {
                SettingsLabel("Your number", symbol: "checkmark.seal", value: saved)
                    .accessibilityIdentifier("settings.agentCalls.number")
                Button("Change Number") { changingNumber = true }
                    .accessibilityIdentifier("settings.agentCalls.changeNumber")
                Button("Remove Number", role: .destructive) { Task { await removeNumber() } }
                    .accessibilityIdentifier("settings.agentCalls.removeNumber")
            } else if let pending = state.pendingNumber {
                Text("Calling \(pending) with a 6-digit code. Enter it here.")
                    .accessibilityIdentifier("settings.agentCalls.pending")
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title3.monospacedDigit())
                    .accessibilityIdentifier("settings.agentCalls.code")
                Button("Confirm") { Task { await confirm() } }
                    .disabled(code.filter(\.isNumber).count != 6 || working)
                    .accessibilityIdentifier("settings.agentCalls.confirm")
                Button("Use Another Number") {
                    self.state?.pendingNumber = nil
                    changingNumber = true
                    code = ""
                }
                .accessibilityIdentifier("settings.agentCalls.anotherNumber")
            } else {
                TextField("+1 415 555 0100", text: $number)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityIdentifier("settings.agentCalls.numberField")
                Button("Call Me With a Code") { Task { await verify() } }
                    .disabled(number.filter(\.isNumber).count < 7 || working)
                    .accessibilityIdentifier("settings.agentCalls.verify")
                if changingNumber, state.number != nil {
                    Button("Cancel") { changingNumber = false }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.colors.label2)
                    .accessibilityIdentifier("settings.agentCalls.problem")
            }
            if let notice {
                Label(notice, systemImage: "phone.arrow.up.right")
                    .accessibilityIdentifier("settings.agentCalls.notice")
            }
        } header: {
            Text("Your number")
        } footer: {
            Text("Include the country code. cmux calls once with a code to check the number is yours.")
        }
    }

    private func topFooter(_ state: AgentCallState) -> String {
        if !state.configured {
            return String(localized: "Phone calls aren’t set up on this cmux service yet. Agent Alarms still ring on this iPhone.")
        }
        if state.number == nil {
            return String(localized: "Add your number below. cmux calls it and reads out what needs you when an agent asks for permission, asks a question or stops.")
        }
        if let from = state.from {
            return String(localized: "Calls come from \(from). Save it as a contact so Focus and Silence Unknown Callers let them through.")
        }
        return String(localized: "cmux calls you and reads out what needs you.")
    }

    private func voiceLine(_ state: AgentCallState) -> String {
        state.voice == "melotts"
            ? String(localized: "Read by MeloTTS, an open text-to-speech model, twice, then the call ends.")
            : String(localized: "Read by the phone provider’s voice, twice, then the call ends.")
    }

    private func nextCall(_ state: AgentCallState, at now: Date) -> String {
        guard let left = state.debounceRemaining(now: now) else { return String(localized: "Ready") }
        return String(localized: "in \(Int(left.rounded(.up))) s")
    }

    private func load() async {
        guard let service else { return }
        do {
            state = try await service.agentCall()
            loadFailed = false
        } catch {
            if state == nil { loadFailed = true }
        }
    }

    private func run(_ body: () async throws -> Void) async {
        working = true
        problem = nil
        notice = nil
        do { try await body() } catch { problem = Self.describe(error) }
        working = false
    }

    private func update(enabled: Bool) async {
        guard let service else { return }
        await run { state = try await service.setAgentCall(enabled: enabled, triggers: nil, clearNumber: false) }
    }

    private func setTrigger(_ trigger: AgentCallTrigger, on: Bool) async {
        guard let service, let state else { return }
        var next = state.triggers.filter { $0 != trigger.rawValue }
        if on { next.append(trigger.rawValue) }
        await run { self.state = try await service.setAgentCall(enabled: nil, triggers: next, clearNumber: false) }
    }

    private func verify() async {
        guard let service else { return }
        await run {
            let calling = try await service.verifyAgentCall(number: number)
            state?.pendingNumber = calling
            changingNumber = false
            code = ""
        }
    }

    private func confirm() async {
        guard let service else { return }
        await run {
            state = try await service.confirmAgentCall(code: code.filter(\.isNumber))
            code = ""
            number = ""
        }
    }

    private func removeNumber() async {
        guard let service else { return }
        await run { state = try await service.setAgentCall(enabled: false, triggers: nil, clearNumber: true) }
    }

    private func test() async {
        guard let service else { return }
        await run {
            let calling = try await service.testAgentCall()
            notice = String(localized: "Calling \(calling)…")
            state = try await service.agentCall()
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let failure = error as? AgentCallFailure else { return String(localized: "Something went wrong. Try again.") }
        return switch failure.code {
        case "wrong_code": String(localized: "That code isn’t right. Check it and try again.")
        case "expired": String(localized: "That code expired. Ask for a new call.")
        case "too_many_tries": String(localized: "Too many wrong codes. Ask for a new call.")
        case "no_code": String(localized: "Ask for a code call first.")
        case "rate_limited": String(localized: "Three code calls this hour already. Try again later.")
        case "debounced": String(localized: "A call went out less than 30 seconds ago. Wait for Next call to read Ready.")
        case "call_failed": String(localized: "The phone provider couldn’t place the call. Check the number and try again.")
        case "calls_not_configured": String(localized: "Phone calls aren’t set up on this cmux service yet.")
        case "bad_request": String(localized: "Enter the number with its country code, like +1 415 555 0100.")
        case "no_number": String(localized: "Add and confirm your number first.")
        default: failure.message
        }
    }
}

/// One Recent line: what called (or didn't), and when.
private struct CallRow: View {
    let entry: AgentCallState.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(entry.decision == "call" ? theme.colors.label.color : theme.colors.label2.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(theme.colors.label2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.agentCalls.recent.\(entry.decision)")
    }

    private var title: String {
        switch entry.trigger {
        case "test": String(localized: "Test call")
        case "verify": String(localized: "Code call")
        default: AgentCallTrigger(rawValue: entry.trigger)?.title ?? entry.trigger
        }
    }

    private var symbol: String {
        switch entry.decision {
        case "call": "phone.fill"
        case "debounced": "timer"
        case "duplicate": "equal.circle"
        case "failed": "xmark.octagon"
        default: "phone.down"
        }
    }

    private var detail: String {
        let time = Date(timeIntervalSince1970: entry.at / 1000).formatted(date: .omitted, time: .standard)
        let outcome = switch entry.decision {
        case "call": String(localized: "Called")
        case "debounced": String(localized: "Held: a call went out less than 30 s before")
        case "duplicate": String(localized: "Already called for this")
        case "trigger_off": String(localized: "Not called: this kind is off")
        case "off": String(localized: "Not called: Phone Calls is off")
        case "no_number": String(localized: "Not called: no number")
        case "failed": String(localized: "Not called: the provider refused (\(entry.reason ?? "error"))")
        default: entry.decision
        }
        return "\(outcome) · \(time)"
    }
}

#if DEBUG
/// A stand-in service for the simulator (mock mode and the capture tests): every state of the
/// page without a phone provider. `CMUX_MOBILE_DEV_AGENT_CALL` picks the start: `unconfigured`,
/// `fresh` (the default), `pending`, `verified`, `history`, `loading` or `unreachable`. The right code is 123456.
@MainActor
public final class AgentCallMockService: AgentCallService {
    private var state: AgentCallState
    private var pendingCode: String?
    private let unreachable: Bool
    private let slow: Bool

    public init(scenario: String) {
        unreachable = scenario == "unreachable"
        slow = scenario == "loading"
        let from = "+1 415 555 0199"
        switch scenario {
        case "unconfigured":
            state = AgentCallState(configured: false)
        case "pending":
            state = AgentCallState(configured: true, from: from, pendingNumber: "+14••• ••0100")
            pendingCode = "123456"
        case "verified":
            state = AgentCallState(configured: true, from: from, enabled: true, number: "+14••• ••0100")
        case "history":
            let now = Date().timeIntervalSince1970 * 1000
            state = AgentCallState(configured: true, from: from, enabled: true, number: "+14••• ••0100", lastCallAt: now - 12_000, log: [
                // Newest first, as the service keeps it; ignored events (duplicate, off) are not kept.
                .init(at: now - 4_000, trigger: "agentFailed", decision: "debounced"),
                .init(at: now - 12_000, trigger: "permission", decision: "call"),
                .init(at: now - 120_000, trigger: "agentFailed", decision: "failed", reason: "twilio_21215"),
                .init(at: now - 180_000, trigger: "needsInput", decision: "call"),
                .init(at: now - 240_000, trigger: "question", decision: "call"),
                .init(at: now - 300_000, trigger: "test", decision: "call"),
                .init(at: now - 600_000, trigger: "verify", decision: "failed", reason: "twilio_21614"),
            ])
        default:
            state = AgentCallState(configured: true, from: from)
        }
    }

    /// The one stand-in mock mode shows, so the page keeps its state between visits.
    public static let shared = AgentCallMockService(scenario: ProcessInfo.processInfo.environment["CMUX_MOBILE_DEV_AGENT_CALL"] ?? "fresh")

    public func agentCall() async throws -> AgentCallState {
        try await Task.sleep(for: slow ? .seconds(120) : .milliseconds(300))
        if unreachable { throw URLError(.timedOut) }
        return state
    }

    public func setAgentCall(enabled: Bool?, triggers: [String]?, clearNumber: Bool) async throws -> AgentCallState {
        if let enabled { state.enabled = enabled && state.number != nil }
        if let triggers { state.triggers = triggers }
        if clearNumber { state.number = nil; state.enabled = false }
        return state
    }

    public func verifyAgentCall(number: String) async throws -> String {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard digits.hasPrefix("+"), digits.count >= 8 else {
            throw AgentCallFailure(code: "bad_request", message: "number must be a phone number with its country code")
        }
        let masked = "\(digits.prefix(3))••• ••\(digits.suffix(4))"
        state.pendingNumber = masked
        pendingCode = "123456"
        return masked
    }

    public func confirmAgentCall(code: String) async throws -> AgentCallState {
        guard let pendingCode, let pending = state.pendingNumber else { throw AgentCallFailure(code: "no_code", message: "no code") }
        guard code == pendingCode else { throw AgentCallFailure(code: "wrong_code", message: "wrong code") }
        self.pendingCode = nil
        state.number = pending
        state.pendingNumber = nil
        state.enabled = true
        return state
    }

    public func testAgentCall() async throws -> String {
        guard let number = state.number else { throw AgentCallFailure(code: "no_number", message: "no number") }
        if state.debounceRemaining(now: Date()) != nil {
            throw AgentCallFailure(code: "debounced", message: "debounced")
        }
        state.lastCallAt = Date().timeIntervalSince1970 * 1000
        log("test", "call")
        return number
    }

    private func log(_ trigger: String, _ decision: String) {
        state.log = Array(([.init(at: Date().timeIntervalSince1970 * 1000, trigger: trigger, decision: decision)] + state.log).prefix(20))
    }
}
#endif
