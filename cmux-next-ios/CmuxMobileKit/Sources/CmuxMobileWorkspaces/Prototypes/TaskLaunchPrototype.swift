#if os(iOS) && DEBUG
import CmuxAgentBrands
import CmuxMobileDesign
import SwiftUI

// PROTOTYPE (DEBUG only): three ways for New Task to choose Chat or Terminal, each with its own
// Model, Effort and Mode pickers whose defaults are the last picks. Opened with
// `-cmux-mobile-prototype-task-launch`; `CMUX_PROTO_VARIANT` (1...3) picks the first variant.
// Nothing outside this file and the DEBUG launch hook uses it; it goes once a variant is chosen.

private let theme = CmuxMobileTheme.standard

/// An agent as the Mac's catalog and its last session describe it (sample data).
struct ProtoAgent: Identifiable, Hashable {
    struct Choice: Identifiable, Hashable {
        var id: String
        var name: String
        /// The pill's word when the name is long ("Ask before edits" → "Ask").
        var short: String
        var detail: String?
    }
    var id: String
    var name: String
    var family: String
    var models: [Choice]
    var efforts: [Choice]
    /// Only the modes that ask before each change: the ones a phone may start (acpmux `remote.modes`).
    var modes: [Choice]

    static let all: [ProtoAgent] = [
        ProtoAgent(id: "claude", name: "Claude Code", family: "claude",
                   models: [.init(id: "opus", name: "Opus", short: "Opus"), .init(id: "sonnet", name: "Sonnet", short: "Sonnet"),
                            .init(id: "haiku", name: "Haiku", short: "Haiku")],
                   efforts: [.init(id: "low", name: "Low", short: "Low"), .init(id: "medium", name: "Medium", short: "Medium"),
                             .init(id: "high", name: "High", short: "High"), .init(id: "max", name: "Max", short: "Max")],
                   modes: [.init(id: "default", name: "Ask before edits", short: "Ask", detail: "Asks before each change"),
                           .init(id: "plan", name: "Plan", short: "Plan", detail: "Plans first, changes nothing")]),
        ProtoAgent(id: "codex", name: "Codex", family: "codex",
                   models: [.init(id: "gpt-5.5", name: "GPT-5.5", short: "GPT-5.5"),
                            .init(id: "gpt-5.5-mini", name: "GPT-5.5 mini", short: "5.5 mini")],
                   efforts: [.init(id: "minimal", name: "Minimal", short: "Minimal"), .init(id: "low", name: "Low", short: "Low"),
                             .init(id: "medium", name: "Medium", short: "Medium"), .init(id: "high", name: "High", short: "High")],
                   modes: [.init(id: "read-only", name: "Read only", short: "Read only", detail: "Reads; asks before any change"),
                           .init(id: "ask", name: "Ask", short: "Ask", detail: "Asks before commands and edits")]),
        ProtoAgent(id: "opencode", name: "OpenCode", family: "opencode",
                   models: [.init(id: "kimi-k2", name: "Kimi K2", short: "Kimi K2"), .init(id: "glm-5", name: "GLM-5", short: "GLM-5")],
                   efforts: [],
                   modes: [.init(id: "ask", name: "Ask", short: "Ask", detail: "Asks before each change")]),
    ]
}

enum ProtoLaunch: String, CaseIterable, Identifiable {
    case chat, terminal
    var id: String { rawValue }
    var title: String { self == .chat ? "Chat" : "Terminal" }
    var symbol: String { self == .chat ? "bubble.left.and.text.bubble.right" : "apple.terminal" }
}

/// The picks, each defaulting to what was picked last (per agent for model, effort and mode).
@MainActor
@Observable
final class ProtoPicks {
    var prompt = "Fix the flaky upload test and open a PR"
    private(set) var agentID: String
    private(set) var model: String
    private(set) var effort: String?
    private(set) var mode: String
    private(set) var launch: ProtoLaunch
    var started: String?

    private let defaults: UserDefaults
    private static let prefix = "cmuxMobile.proto.taskLaunch."
    private static var didReset = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Once per launch: SwiftUI makes this again on each redraw of the screen that holds it
        // (only the first is kept), and a reset each time wiped the picks just saved.
        if CommandLine.arguments.contains("-cmux-proto-reset"), !Self.didReset {
            Self.didReset = true
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) { defaults.removeObject(forKey: key) }
        }
        let agentID = defaults.string(forKey: Self.prefix + "agent") ?? ProtoAgent.all[0].id
        let agent = ProtoAgent.all.first { $0.id == agentID } ?? ProtoAgent.all[0]
        self.agentID = agent.id
        (model, effort, mode) = Self.remembered(agent, defaults)
        launch = ProtoLaunch(rawValue: defaults.string(forKey: Self.prefix + "launch") ?? "") ?? .terminal
    }

    var agent: ProtoAgent { ProtoAgent.all.first { $0.id == agentID } ?? ProtoAgent.all[0] }
    var modelChoice: ProtoAgent.Choice? { agent.models.first { $0.id == model } }
    var effortChoice: ProtoAgent.Choice? { agent.efforts.first { $0.id == effort } }
    var modeChoice: ProtoAgent.Choice? { agent.modes.first { $0.id == mode } }

    /// An agent's last model, effort and mode, else its first (the Mac's start values).
    private static func remembered(_ agent: ProtoAgent, _ defaults: UserDefaults) -> (String, String?, String) {
        func last(_ key: String, in list: [ProtoAgent.Choice]) -> String? {
            let saved = defaults.string(forKey: prefix + agent.id + "." + key)
            return list.contains { $0.id == saved } ? saved : nil
        }
        let effort = last("effort", in: agent.efforts) ?? (agent.efforts.count > 2 ? agent.efforts[2].id : agent.efforts.first?.id)
        return (last("model", in: agent.models) ?? agent.models[0].id, effort, last("mode", in: agent.modes) ?? agent.modes[0].id)
    }

    func pick(agent id: String) {
        guard let next = ProtoAgent.all.first(where: { $0.id == id }) else { return }
        agentID = id
        (model, effort, mode) = Self.remembered(next, defaults)
        defaults.set(id, forKey: Self.prefix + "agent")
        defaults.synchronize()
    }
    func pick(model id: String) { model = id; defaults.set(id, forKey: Self.prefix + agentID + ".model") }
    func pick(effort id: String) { effort = id; defaults.set(id, forKey: Self.prefix + agentID + ".effort") }
    func pick(mode id: String) { mode = id; defaults.set(id, forKey: Self.prefix + agentID + ".mode"); defaults.synchronize() }
    func pick(launch: ProtoLaunch) { self.launch = launch; defaults.set(launch.rawValue, forKey: Self.prefix + "launch") }

    /// Start: what would be sent, said once (the prototype starts nothing).
    func start(in launch: ProtoLaunch) {
        pick(launch: launch)
        let parts = [agent.name, modelChoice?.name, effortChoice.map { "\($0.name) effort" }, modeChoice?.name].compactMap { $0 }
        started = "Started in \(launch == .chat ? "a chat" : "a terminal"): " + parts.joined(separator: " · ")
    }
}

/// The prototype: a variant switcher (harness chrome, not part of any design) over the composer.
struct TaskLaunchPrototype: View {
    let close: () -> Void
    @State private var variant: Int
    @State private var picks = ProtoPicks()

    static let names = ["Top switch", "Two Starts", "Setup card"]

    init(close: @escaping () -> Void) {
        self.close = close
        let first = Int(ProcessInfo.processInfo.environment["CMUX_PROTO_VARIANT"] ?? "") ?? 1
        _variant = State(initialValue: min(max(first, 1), Self.names.count))
    }

    var body: some View {
        // The picker above the variant's own navigation bar (a top inset collapsed the bar).
        VStack(spacing: 0) {
            picker
            Group {
                switch variant {
                case 1: ProtoTopSwitch(picks: picks, close: close)
                case 2: ProtoTwoStarts(picks: picks, close: close)
                default: ProtoSetupCard(picks: picks, close: close)
                }
            }
            // Instant switch: flipping variants is the harness's most frequent action.
            .id(variant)
        }
        .overlay(alignment: .center) {
            if let started = picks.started {
                ProtoStartedNote(text: started) { picks.started = nil }
            }
        }
    }

    /// The prototype picker: a dark pill, the same in every variant and both looks.
    private var picker: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.names.enumerated()), id: \.offset) { index, name in
                let active = variant == index + 1
                Button { variant = index + 1 } label: {
                    Text(name)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(active ? Color.white.opacity(0.12) : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proto.picker.\(index + 1)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color(white: 0.04).opacity(0.82), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(theme.colors.bg.color)
    }
}

// MARK: - Shared pieces

/// The composer's canvas, nav bar and keyboard focus, with each variant's own parts around it.
private struct ProtoComposer<Header: View, Accessory: View, Principal: View>: View {
    @Bindable var picks: ProtoPicks
    let close: () -> Void
    @ViewBuilder var principal: Principal
    @ViewBuilder var header: Header
    @ViewBuilder var accessory: Accessory
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ZStack(alignment: .topLeading) {
                    if picks.prompt.isEmpty {
                        Text("Describe a coding task in cmux")
                            .font(.title3)
                            .foregroundStyle(theme.colors.label3.color)
                            .padding(.top, 26)
                            .padding(.horizontal, 25)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $picks.prompt)
                        .font(.title3)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("proto.prompt")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { accessory.padding(.bottom, 8) }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("proto.back")
                }
                ToolbarItem(placement: .principal) { principal }
                ToolbarItem(placement: .primaryAction) {
                    Button {} label: { Image(systemName: "tray") }.accessibilityLabel("Drafts")
                }
            }
        }
        .onAppear { focused = true }
    }
}

private struct ProtoTitle: View {
    var body: some View {
        Text("cmux").font(.headline)
    }
}

/// A menu whose label is a Liquid Glass pill: an icon or the agent's mark, then the pick.
private struct ProtoPill<Content: View>: View {
    let id: String
    let label: String
    var symbol: String?
    var family: String?
    let value: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 5) {
                if let family {
                    AgentBrandMark(agent: family, size: 15, style: .brand).frame(width: 16, height: 16)
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(theme.colors.label2.color)
                }
                Text(value).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.colors.label2.color)
            }
            .modifier(TaskComposerPillLabel(isError: false))
        }
        .menuOrder(.fixed)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }
}

/// The menus' contents: one picker each, checkmark on the current pick, section titles naming
/// what it is and that it's remembered.
private enum ProtoMenus {
    @MainActor @ViewBuilder
    static func agents(_ picks: ProtoPicks) -> some View {
        Picker("Agent", selection: Binding(get: { picks.agentID }, set: { picks.pick(agent: $0) })) {
            ForEach(ProtoAgent.all) { agent in Text(agent.name).tag(agent.id) }
        }
        .pickerStyle(.inline)
    }

    @MainActor @ViewBuilder
    static func models(_ picks: ProtoPicks) -> some View {
        Section("\(picks.agent.name) models") {
            Picker("Model", selection: Binding(get: { picks.model }, set: { picks.pick(model: $0) })) {
                ForEach(picks.agent.models) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
        }
    }

    @MainActor @ViewBuilder
    static func efforts(_ picks: ProtoPicks) -> some View {
        Section("How hard it thinks") {
            Picker("Effort", selection: Binding(get: { picks.effort ?? "" }, set: { picks.pick(effort: $0) })) {
                ForEach(picks.agent.efforts) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
        }
    }

    @MainActor @ViewBuilder
    static func modes(_ picks: ProtoPicks) -> some View {
        Section("Modes a phone can start") {
            Picker("Mode", selection: Binding(get: { picks.mode }, set: { picks.pick(mode: $0) })) {
                ForEach(picks.agent.modes) { mode in
                    // Two lines in a menu row: the mode, then what it does.
                    VStack {
                        Text(mode.name)
                        if let detail = mode.detail { Text(detail) }
                    }
                    .tag(mode.id)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

private struct ProtoCircle: View {
    let symbol: String
    let id: String
    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.colors.label.color)
            .frame(width: 38, height: 38)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .accessibilityIdentifier(id)
    }
}

private struct ProtoAttach: View {
    var body: some View {
        Menu {
            Button("Paste", systemImage: "doc.on.clipboard") {}
            Button("Choose Files", systemImage: "folder") {}
            Button("Photo Library", systemImage: "photo.on.rectangle") {}
        } label: { ProtoCircle(symbol: "plus", id: "proto.attach") }
            .menuOrder(.fixed)
            .accessibilityLabel("Attach")
    }
}

private struct ProtoStartedNote: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(theme.colors.accent.color)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
            Button("OK", action: dismiss).buttonStyle(.glass).accessibilityIdentifier("proto.started.ok")
        }
        .padding(20)
        .frame(maxWidth: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proto.started")
    }
}

// MARK: - 1. Top switch: Chat | Terminal in the bar; a row of separate pickers above the keyboard

private struct ProtoTopSwitch: View {
    @Bindable var picks: ProtoPicks
    let close: () -> Void

    var body: some View {
        ProtoComposer(picks: picks, close: close) {
            Picker("Open in", selection: Binding(get: { picks.launch }, set: { picks.pick(launch: $0) })) {
                ForEach(ProtoLaunch.allCases) { launch in
                    Label(launch.title, systemImage: launch.symbol).labelStyle(.titleOnly).tag(launch)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .accessibilityIdentifier("proto.openIn")
        } header: {
            EmptyView()
        } accessory: {
            VStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    pickers(icons: true)
                    pickers(icons: false)
                }
                .padding(.horizontal, 12)
                HStack(spacing: 0) {
                    Button {} label: { ProtoCircle(symbol: "slider.horizontal.3", id: "proto.options") }.buttonStyle(.plain)
                    ProtoAttach()
                    Spacer(minLength: 0)
                    Button { picks.start(in: picks.launch) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: picks.launch.symbol)
                            Text("Start")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.colors.onAccent.color)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .glassEffect(.regular.tint(theme.colors.accent.color).interactive(), in: .capsule)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start in \(picks.launch.title)")
                    .accessibilityIdentifier("proto.start")
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func pickers(icons: Bool) -> some View {
        HStack(spacing: 6) {
            ProtoPill(id: "proto.agent", label: "Agent", family: picks.agent.family, value: picks.agent.name) { ProtoMenus.agents(picks) }
            ProtoPill(id: "proto.model", label: "Model", symbol: icons ? "cpu" : nil, value: picks.modelChoice?.short ?? "") {
                ProtoMenus.models(picks)
            }
            if let effort = picks.effortChoice {
                ProtoPill(id: "proto.effort", label: "Effort", symbol: icons ? "gauge.with.dots.needle.67percent" : nil,
                          value: effort.short) { ProtoMenus.efforts(picks) }
            }
            ProtoPill(id: "proto.mode", label: "Mode", symbol: icons ? "hand.raised" : nil, value: picks.modeChoice?.short ?? "") {
                ProtoMenus.modes(picks)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 2. Two Starts: the Start buttons choose; the last one used is the filled one

private struct ProtoTwoStarts: View {
    @Bindable var picks: ProtoPicks
    let close: () -> Void

    var body: some View {
        ProtoComposer(picks: picks, close: close) {
            ProtoTitle()
        } header: {
            EmptyView()
        } accessory: {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProtoPill(id: "proto.agent", label: "Agent", family: picks.agent.family, value: picks.agent.name) {
                        ProtoMenus.agents(picks)
                    }
                    settings
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                HStack(spacing: 8) {
                    Button {} label: { ProtoCircle(symbol: "slider.horizontal.3", id: "proto.options") }.buttonStyle(.plain)
                    ProtoAttach()
                    Spacer(minLength: 0)
                    // The other one first: the filled, last-used Start sits where the thumb is.
                    ForEach([picks.launch == .chat ? ProtoLaunch.terminal : .chat, picks.launch]) { launch in
                        startButton(launch)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    /// Model, effort and mode: three menus in one glass capsule, split by hairlines.
    private var settings: some View {
        HStack(spacing: 0) {
            segment("proto.model", "Model", picks.modelChoice?.short ?? "") { ProtoMenus.models(picks) }
            if let effort = picks.effortChoice {
                divider
                segment("proto.effort", "Effort", effort.short) { ProtoMenus.efforts(picks) }
            }
            divider
            segment("proto.mode", "Mode", picks.modeChoice?.short ?? "") { ProtoMenus.modes(picks) }
        }
        .font(.caption.weight(.semibold))
        .frame(height: 38)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(minHeight: 44)
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(theme.colors.label3.color.opacity(0.5)).frame(width: 1, height: 18)
    }

    private func segment<C: View>(_ id: String, _ label: String, _ value: String, @ViewBuilder _ content: () -> C) -> some View {
        Menu { content() } label: {
            Text(value)
                .foregroundStyle(theme.colors.label.color)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 38)
                .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    private func startButton(_ launch: ProtoLaunch) -> some View {
        let primary = launch == picks.launch
        return Button { picks.start(in: launch) } label: {
            HStack(spacing: 6) {
                Image(systemName: launch.symbol)
                Text(launch.title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primary ? theme.colors.onAccent.color : theme.colors.label.color)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .glassEffect(primary ? .regular.tint(theme.colors.accent.color).interactive() : .regular.interactive(), in: .capsule)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start in \(launch.title)")
        .accessibilityIdentifier("proto.start.\(launch.rawValue)")
    }
}

// MARK: - 3. Setup card: one line over the prompt that opens into labelled rows

private struct ProtoSetupCard: View {
    @Bindable var picks: ProtoPicks
    let close: () -> Void
    @State private var open = CommandLine.arguments.contains("-cmux-proto-open-card")

    var body: some View {
        ProtoComposer(picks: picks, close: close) {
            ProtoTitle()
        } header: {
            card
                .padding(.horizontal, 16)
                .padding(.top, 8)
        } accessory: {
            HStack(spacing: 0) {
                Button {} label: { ProtoCircle(symbol: "slider.horizontal.3", id: "proto.options") }.buttonStyle(.plain)
                ProtoAttach()
                Spacer(minLength: 0)
                Button { picks.start(in: picks.launch) } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.colors.onAccent.color)
                        .frame(width: 38, height: 38)
                        .glassEffect(.regular.tint(theme.colors.accent.color).interactive(), in: .circle)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start in \(picks.launch.title)")
                .accessibilityIdentifier("proto.start")
            }
            .padding(.horizontal, 12)
        }
    }

    private var summary: String {
        [picks.agent.name, picks.modelChoice?.short, picks.effortChoice?.short, picks.modeChoice?.short, picks.launch.title]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var card: some View {
        VStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    AgentBrandMark(agent: picks.agent.family, size: 15, style: .brand).frame(width: 16, height: 16)
                    Text(summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.colors.label.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.colors.label2.color)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Task setup")
            .accessibilityValue(summary)
            .accessibilityIdentifier("proto.setup.toggle")
            if open {
                Divider().padding(.leading, 14)
                row("Agent", picks.agent.name, id: "proto.agent") { ProtoMenus.agents(picks) }
                Divider().padding(.leading, 14)
                row("Model", picks.modelChoice?.name ?? "", id: "proto.model") { ProtoMenus.models(picks) }
                if let effort = picks.effortChoice {
                    Divider().padding(.leading, 14)
                    row("Effort", effort.name, id: "proto.effort") { ProtoMenus.efforts(picks) }
                }
                Divider().padding(.leading, 14)
                row("Mode", picks.modeChoice?.name ?? "", id: "proto.mode") { ProtoMenus.modes(picks) }
                Divider().padding(.leading, 14)
                HStack {
                    Text("Open in").font(.subheadline).foregroundStyle(theme.colors.label2.color)
                    Spacer()
                    Picker("Open in", selection: Binding(get: { picks.launch }, set: { picks.pick(launch: $0) })) {
                        ForEach(ProtoLaunch.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .accessibilityIdentifier("proto.openIn")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func row<C: View>(_ title: String, _ value: String, id: String, @ViewBuilder _ content: () -> C) -> some View {
        Menu { content() } label: {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(theme.colors.label2.color)
                Spacer()
                Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(theme.colors.label.color)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.label3.color)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }
}
#endif
