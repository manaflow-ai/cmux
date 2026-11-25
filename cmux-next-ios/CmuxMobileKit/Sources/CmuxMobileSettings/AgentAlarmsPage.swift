import CmuxMobileDesign
import CmuxMobileNotifications
import SwiftUI
import UIKit

/// Settings → Notifications → Agent Alarms: an AlarmKit alarm (it rings through Silent and
/// Focus, like the Clock app's) when a coding agent is stuck on the person. The rule lives in
/// `AgentAlarmGate` (one alarm per event, at most one in any 30 seconds); the preferences sit
/// where the notification service extension reads them, so a push rings with cmux closed too.
struct AgentAlarmsPage: View {
    private let store: AgentAlarmStore
    private let ringer: any AgentAlarmRinging
    @State private var preferences: AgentAlarmPreferences
    @State private var ledger: AgentAlarmLedger
    @State private var authorization: AgentAlarmAuthorization
    @State private var asking = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(store: AgentAlarmStore = .live(), ringer: any AgentAlarmRinging = AgentAlarmRinger.live) {
        self.store = store
        self.ringer = ringer
        _preferences = State(initialValue: store.preferences())
        _ledger = State(initialValue: store.ledger())
        _authorization = State(initialValue: ringer.authorization())
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { preferences.enabled }, set: { setEnabled($0) })) {
                    SettingsLabel("Agent Alarms", symbol: "alarm")
                }
                .disabled(asking || authorization == .unavailable)
                .accessibilityIdentifier("settings.agentAlarms.enabled")
                permissionRow
            } footer: {
                Text(footer)
            }
            Section {
                ForEach(AgentAlarmTrigger.allCases) { trigger in
                    Toggle(isOn: Binding(get: { preferences.triggers.contains(trigger) },
                                         set: { setTrigger(trigger, on: $0) })) {
                        SettingsLabel(verbatim: trigger.title, symbol: trigger.symbol)
                    }
                    .accessibilityIdentifier("settings.agentAlarms.trigger.\(trigger.rawValue)")
                }
            } header: {
                Text("Ring for")
            } footer: {
                Text("“Mac stopped responding” rings when a Mac this iPhone was connected to gives no answer for a minute while cmux is open.")
            }
            .disabled(!preferences.enabled)
            .opacity(preferences.enabled ? 1 : 0.4)
            Section {
                Button {
                    Task { await test() }
                } label: {
                    SettingsLabel("Test Alarm", symbol: "alarm.waves.left.and.right")
                }
                .disabled(!preferences.enabled || authorization != .authorized)
                .accessibilityIdentifier("settings.agentAlarms.test")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SettingsLabel("Next alarm", symbol: "timer", value: nextAlarm(at: context.date))
                        .accessibilityIdentifier("settings.agentAlarms.debounce")
                }
            } footer: {
                Text("At most one alarm rings in any 30 seconds. An event that arrives sooner still sends its notification, without the alarm.")
            }
            Section {
                if ledger.history.isEmpty {
                    Text("No alarms yet.")
                        .foregroundStyle(theme.colors.label2)
                        .accessibilityIdentifier("settings.agentAlarms.recent.empty")
                } else {
                    ForEach(ledger.history) { entry in
                        RecentRow(entry: entry)
                    }
                    Button(role: .destructive) {
                        store.resetLedger()
                        reload()
                    } label: {
                        Text("Clear")
                    }
                    .accessibilityIdentifier("settings.agentAlarms.clear")
                }
            } header: {
                Text("Recent")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("cmux open or in the background: alarms ring from the live Feed and from each push.")
                    Text("cmux closed or swiped away: each permission, question or error push rings from the notification extension.")
                    Text("No push, no alarm: with the iPhone off or without a network, or notifications from your Macs off, nothing rings.")
                }
                .font(.footnote)
                .foregroundStyle(theme.colors.label2)
                .accessibilityIdentifier("settings.agentAlarms.howItWorks")
            } header: {
                Text("When cmux isn’t open")
            }
        }
        .settingsPage("Agent Alarms")
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    @ViewBuilder private var permissionRow: some View {
        switch authorization {
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                SettingsLabel("Alarm permission", symbol: "lock", value: authorization.title)
            }
            .accessibilityIdentifier("settings.agentAlarms.permission")
        default:
            SettingsLabel("Alarm permission", symbol: authorization == .authorized ? "checkmark.shield" : "shield",
                          value: authorization.title)
                .accessibilityIdentifier("settings.agentAlarms.permission")
        }
    }

    private var footer: String {
        switch authorization {
        case .unavailable: String(localized: "Alarms need iOS 26 or later.")
        case .denied: String(localized: "Alarms are off for cmux in iOS Settings. Turn on Alarms & Timers for cmux to use Agent Alarms.")
        case .notDetermined: String(localized: "Turning this on asks iOS to let cmux set alarms. They ring through Silent mode and Focus, like the Clock app’s.")
        case .authorized: String(localized: "An alarm rings when an agent needs permission, asks a question, waits in a terminal or stops. It stops by itself once the ask is answered.")
        }
    }

    private func nextAlarm(at now: Date) -> String {
        guard let left = ledger.debounceRemaining(now: now) else { return String(localized: "Ready") }
        return String(localized: "in \(Int(left.rounded(.up))) s")
    }

    private func setEnabled(_ on: Bool) {
        guard on else { return save { $0.enabled = false } }
        guard authorization != .authorized else { return save { $0.enabled = true } }
        asking = true
        Task {
            let answer = await ringer.requestAuthorization()
            authorization = answer
            asking = false
            if answer == .authorized { save { $0.enabled = true } }
        }
    }

    private func setTrigger(_ trigger: AgentAlarmTrigger, on: Bool) {
        save { preferences in
            if on { preferences.triggers.insert(trigger) } else { preferences.triggers.remove(trigger) }
        }
    }

    private func save(_ change: (inout AgentAlarmPreferences) -> Void) {
        var next = preferences
        change(&next)
        preferences = next
        store.save(next)
    }

    private func test() async {
        await AgentAlarms.handle(.permission, key: "test:\(UUID().uuidString)", agent: String(localized: "Test agent"),
                                 source: .test, store: store, ringer: ringer, overrideTrigger: true)
        reload()
    }

    private func reload() {
        preferences = store.preferences()
        ledger = store.ledger()
        authorization = ringer.authorization()
    }
}

/// One Recent line: what rang (or didn't), from where, when.
private struct RecentRow: View {
    let entry: AgentAlarmLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(theme.colors.label2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.agentAlarms.recent.\(entry.outcome.rawValue)")
    }

    private var symbol: String {
        switch entry.outcome {
        case .rang: "alarm.fill"
        case .debounced: "timer"
        case .duplicate: "equal.circle"
        case .notAllowed: "lock"
        case .failed: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch entry.outcome {
        case .rang: theme.colors.label.color
        default: theme.colors.label2.color
        }
    }

    private var detail: String {
        let time = entry.at.formatted(date: .omitted, time: .standard)
        let outcome = switch entry.outcome {
        case .rang: String(localized: "Rang")
        case .debounced: String(localized: "Held: another alarm rang \(Int(AgentAlarmGate.debounce - (entry.wait ?? 0))) s before")
        case .duplicate: String(localized: "Already rang")
        case .notAllowed: String(localized: "Not rung: alarm permission is off")
        case .failed: String(localized: "Not rung: iOS refused the alarm")
        }
        return "\(outcome) · \(entry.source.title) · \(time)"
    }
}
