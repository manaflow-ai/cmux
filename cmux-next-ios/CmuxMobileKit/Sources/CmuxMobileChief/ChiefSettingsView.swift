#if os(iOS)
import CmuxConversationCore
import CmuxMobileDesign
import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "chief-settings")

/// Chief's info, laid out as Messages' contact details (iOS 26
/// CommunicationDetails): the avatar in the navigation bar's row between the
/// back chevron and Edit, the name and status under it, round quick actions,
/// then inset grouped cards over a backdrop tinted by the avatar.
///
/// It holds what the Mac's Chief settings sidebar offers its owner
/// (HomeChiefSidebar: harness, model and effort; the name and avatar under
/// Edit), Stop for a running turn, the recent turns, and this phone's Hide
/// Alerts and Send Read Receipts. It replaces CmuxConversation's contact
/// details for Chief, whose Call, FaceTime and Mail have no meaning here.
/// Every control acts on the Mac's Chief or on this phone's settings;
/// nothing here is decoration.
///
/// Pushed from the conversation header (``ChiefConversationScreen``), as
/// Messages pushes details: the back chevron and the edge swipe return.
public struct ChiefSettingsView: View {
    let session: ChiefSession
    /// Message: back to the conversation with the keyboard up.
    let onMessage: (() -> Void)?
    @State private var report: ChiefEngineReport?
    /// A change or stop the Mac did not take (a failed read is the session's ``ChiefSession/engineProblem``).
    @State private var engineError: String?
    @State private var saving = false
    @State private var stopping = false
    @State private var stopNote: String?
    @State private var muted: Bool
    @State private var receipts: Bool
    /// The window's top safe inset (the status bar): Messages' avatar top.
    @State private var windowSafeTop: CGFloat = Self.lastWindowSafeTop
    /// The header row's top at rest, in the window (the list runs under the
    /// bar, so this is near the screen's top); -1 until measured.
    @State private var restRowTop: CGFloat = Self.lastRestRowTop
    /// How far the cards are scrolled from rest.
    @State private var scrolled: CGFloat = 0

    // Kept across pushes so the next push lays out at once, without a jump.
    @MainActor private static var lastWindowSafeTop: CGFloat = sceneSafeTop()
    @MainActor private static var lastRestRowTop: CGFloat = -1

    /// The key window's top inset, before this page has a window of its own.
    @MainActor private static func sceneSafeTop() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.lazy.compactMap(\.keyWindow).first?.safeAreaInsets.top ?? 0
    }

    public init(session: ChiefSession, onMessage: (() -> Void)? = nil) {
        self.session = session
        self.onMessage = onMessage
        _muted = State(initialValue: session.isMuted)
        _receipts = State(initialValue: session.sendsReadReceipts)
        _report = State(initialValue: session.engineReport)
    }

    private var hasControl: Bool { session.control != nil }
    private var name: String { session.title ?? session.identity.title }

    public var body: some View {
        Form {
            engineSection
            if hasControl, !(report?.recent.isEmpty ?? true) { recentSection }
            notificationsSection
            #if DEBUG
            diagnosticsSection
            #endif
            Section {
            } footer: {
                Text("Chief's memory and traces open on the Mac.")
            }
        }
        .listSectionSpacing(ChiefInfoGeometry.sectionGap)
        .scrollContentBackground(.hidden)
        // Messages' details: the bar floats over the content, and the avatar
        // sits in the bar's row. The list starts under the bar, so the header
        // is never clipped to its row.
        .ignoresSafeArea(.container, edges: .top)
        .background { ChiefInfoBackdrop() }
        .background { WindowSafeTopReader { windowSafeTop = $0; Self.lastWindowSafeTop = $0 } }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, now in
            scrolled = now
        }
        // The avatar sits in the bar's row at rest, as in Messages: no
        // edge blur over it until the cards scroll under the bar.
        .scrollEdgeEffectHidden(scrolled < ChiefInfoGeometry.edgeEffectAfter, for: .top)
        // The header names Chief: no title in the bar, as Messages. The
        // title still names the page for VoiceOver and the back menu.
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Messages' Edit: Chief's name and avatar, on a Mac that sets them.
            if hasControl {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ChiefIdentityEditor(session: session)
                    } label: {
                        Text("Edit")
                    }
                    .accessibilityIdentifier("chief.settings.edit")
                }
            }
        }
        // Reads Chief's engine now, and again with backoff while the
        // Mac or its model server is down, until the page closes; again
        // once Chief connects with the page open.
        .task(id: hasControl) { await session.watchEngine() }
        .onChange(of: session.engineReport) { _, newer in if !saving { report = newer } }
        // Hide Alerts changed elsewhere (Home's pin menu): the switch follows, animated.
        .onChange(of: session.isMuted) { _, on in if muted != on { withAnimation { muted = on } } }
        .onChange(of: session.sendsReadReceipts) { _, on in if receipts != on { withAnimation { receipts = on } } }
        .accessibilityIdentifier("chief.settings")
    }

    // MARK: Sections

    /// The header's top padding: from the row's resting top down to the
    /// status bar's bottom, where Messages' avatar starts.
    private var headerTop: CGFloat {
        guard windowSafeTop > 0, restRowTop >= 0 else { return windowSafeTop }
        return max(0, windowSafeTop - restRowTop)
    }

    /// The engine card's section header, so the gap to the first card is the
    /// list's header gap whatever that section's footer holds.
    private var header: some View {
            VStack(spacing: 0) {
                ChiefAvatar(text: session.avatar, size: ChiefInfoGeometry.avatarSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Avatar, \(session.avatar)"))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("chief.settings.avatarImage")
                    .padding(.bottom, ChiefInfoGeometry.titleTopFromAvatar - ChiefInfoGeometry.avatarSize)
                // Explicit label colors: a section header's hierarchical
                // styles are one level dimmer (`.primary` would draw gray).
                Text(name)
                    .font(.title.bold())
                    .foregroundStyle(Color(uiColor: .label))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("chief.settings.title")
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .accessibilityIdentifier("chief.settings.status")
                quickActions
                    .padding(.top, ChiefInfoGeometry.quickActionsBelowTitle)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, ChiefInfoGeometry.sectionGap - ChiefInfoGeometry.listGapAfterHeader)
            .frame(maxWidth: .infinity)
            .padding(.top, headerTop)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                // The row's own frame: the padding is inside it, so it does
                // not move what it is measured from. Only at rest: while
                // scrolling, this and the scroll offset may arrive in either
                // order within a frame.
                guard abs(scrolled) < 0.5, top >= 0, abs(top - restRowTop) > 0.5 else { return }
                restRowTop = top
                Self.lastRestRowTop = top
            }
            .textCase(nil)
            .listRowInsets(EdgeInsets())
    }

    /// Messages' call / video / mail circles, with Chief's own real actions:
    /// Message (back to the conversation, keyboard up), Call (a live voice
    /// call) and Stop (Chief's running turn; dimmed while there is none, as
    /// Messages dims an action a contact cannot take).
    private var quickActions: some View {
        HStack(spacing: ChiefInfoGeometry.quickActionSpacing) {
            if let onMessage {
                ChiefQuickAction(symbol: "message.fill", title: String(localized: "Message"), enabled: true) { onMessage() }
                    .accessibilityIdentifier("chief.settings.message")
            }
            ChiefQuickAction(symbol: "phone.fill", title: String(localized: "Call"), enabled: true) {
                ChiefCallLauncher.shared.call()
            }
            .accessibilityIdentifier("chief.settings.call")
            if !session.runsInCloud {
                ChiefQuickAction(symbol: "stop.fill", title: String(localized: "Stop"),
                                 enabled: hasControl && session.isTyping && !stopping,
                                 busy: stopping) { Task { await stop() } }
                    .accessibilityIdentifier("chief.settings.stop")
            }
        }
    }

    /// Never claims Chief runs on a Mac it cannot reach: without the Mac's
    /// control channel the status is the reason, matching the Model row.
    private var statusLine: String {
        if session.runsInCloud {
            if !session.isConnected { return session.unavailableReason ?? String(localized: "Connecting to cmux Cloud") }
            return session.isWorking ? String(localized: "Working in cmux Cloud") : String(localized: "Runs in cmux Cloud")
        }
        guard hasControl else {
            return session.unavailableReason ?? String(localized: "Not connected to your Mac")
        }
        let mac = session.macName ?? String(localized: "your Mac")
        if session.isTyping { return String(localized: "Working on \(mac)") }
        return String(localized: "Runs on \(mac)")
    }

    @ViewBuilder private var engineSection: some View {
        Section {
            if session.runsInCloud {
                Text("This Chief runs in cmux Cloud.")
                    .foregroundStyle(.secondary)
            } else if !hasControl {
                Text("Connect to your Mac to choose Chief's model.")
                    .foregroundStyle(.secondary)
                if let report, let model = Self.currentModelName(report) {
                    LabeledContent("Model", value: model)
                        .accessibilityIdentifier("chief.settings.lastModel")
                }
            } else if let report {
                Picker("Harness", selection: binding(\.harness, report.engine.harness ?? "claude")) {
                    ForEach(report.harnesses, id: \.self) { Text(Self.harnessName($0)).tag($0) }
                }
                .accessibilityIdentifier("chief.settings.harness")
                Picker("Model", selection: binding(\.model, report.choice.model ?? "default")) {
                    Text(Self.defaultModelLabel(report)).tag("default")
                    ForEach(report.pickableModels, id: \.id) { Text($0.name).tag($0.id) }
                    if let chosen = report.choice.model, chosen != "default",
                       !report.pickableModels.contains(where: { $0.id == chosen }) {
                        Text(chosen).tag(chosen)
                    }
                }
                .accessibilityIdentifier("chief.settings.model")
                // No effort to pick on a harness that takes none: no row,
                // rather than a picker that does nothing.
                if !report.offered.efforts.isEmpty || report.choice.effort != nil {
                    Picker("Effort", selection: binding(\.effort, report.choice.effort ?? "default")) {
                        Text(Self.defaultLabel(report.engine.effort.map(Self.effortName))).tag("default")
                        ForEach(report.offered.efforts, id: \.self) { Text(Self.effortName($0)).tag($0) }
                        if let chosen = report.choice.effort, !report.offered.efforts.contains(chosen) {
                            Text(Self.effortName(chosen)).tag(chosen)
                        }
                    }
                    .accessibilityIdentifier("chief.settings.effort")
                }
            } else if session.engineProblem == nil {
                // The spinner trails, as on Try Again: the text keeps the rows' x (no icons here).
                HStack { Text("Asking Chief on the Mac…").foregroundStyle(.secondary); Spacer(); ProgressView() }
            }
            // A failed read never replaces the model: it is said under it,
            // with Try Again (the page also retries on its own).
            if hasControl, let problem = session.engineProblem {
                Text(problem.loadText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chief.settings.problem")
                Button {
                    Task { await retry() }
                } label: {
                    HStack {
                        Text("Try Again")
                        if retrying { Spacer(); ProgressView() }
                    }
                }
                .disabled(retrying)
                .accessibilityIdentifier("chief.settings.retry")
            }
            // The model list is Chief's own; its model server shows in the
            // turns: the newest one failed to reach it.
            if hasControl, session.engineProblem == nil, let status = session.lastTurnFailure?.modelStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chief.settings.modelStatus")
            }
            if let engineError {
                Text(engineError).font(.footnote).foregroundStyle(.red)
            }
            if let stopNote {
                Text(stopNote).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            header
        } footer: {
            if hasControl {
                Text("Changes apply to Chief's next turn, on every device.")
            }
        }
        .listRowBackground(ChiefInfoGeometry.card)
        // Links and actions in system blue, as Messages' rows (the bar and
        // the Edit pages keep the app's tint).
        .tint(Color(uiColor: .systemBlue))
    }

    private var recentSection: some View {
        Section("Recent Turns") {
            ForEach(Array((report?.recent ?? []).prefix(5).enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.turnTitle(turn, in: report))
                        .font(.subheadline)
                    Text(Self.turnLine(turn))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .listRowBackground(ChiefInfoGeometry.card)
    }

    /// This phone's switches: they need the conversation, so without it they
    /// show the standard disabled dimming.
    private var notificationsSection: some View {
        Section {
            Toggle("Hide Alerts", isOn: $muted)
                .tint(Color(uiColor: .systemGreen))
                .accessibilityIdentifier("chief.settings.hideAlerts")
                .onChange(of: muted) { _, on in
                    guard on != session.isMuted else { return }
                    session.setMuted(on) { withAnimation { muted = !on } }
                }
            Toggle("Send Read Receipts", isOn: $receipts)
                .tint(Color(uiColor: .systemGreen))
                .accessibilityIdentifier("chief.settings.readReceipts")
                .onChange(of: receipts) { _, on in
                    guard on != session.sendsReadReceipts else { return }
                    session.setSendsReadReceipts(on) { withAnimation { receipts = !on } }
                }
        } footer: {
            Text("Hide Alerts silences Chief's notifications on this iPhone. With Send Read Receipts off, reading Chief here does not mark it read on your Mac.")
        }
        .disabled(session.conversationID == nil)
        .listRowBackground(ChiefInfoGeometry.card)
    }

    // MARK: Actions

    @State private var retrying = false

    private func retry() async {
        retrying = true
        defer { retrying = false }
        await session.refreshEngine()
    }

    /// A picker bound to one engine field: picking writes it on the Mac and
    /// shows the brain's answer; a refusal puts the old value back.
    private func binding(_ field: WritableKeyPath<ChiefEngineReport.Engine, String?>, _ current: String) -> Binding<String> {
        Binding {
            current
        } set: { value in
            guard value != current, let control = session.control, !saving else { return }
            let before = report
            report?.choice[keyPath: field] = value == "default" ? nil : value
            if value != "default" { report?.engine[keyPath: field] = value }
            saving = true
            Task {
                defer { saving = false }
                do {
                    let answer = switch field {
                    case \.harness: try await control.setEngine(harness: value)
                    case \.model: try await control.setEngine(model: value)
                    default: try await control.setEngine(effort: value)
                    }
                    report = answer
                    session.adopt(answer)
                    engineError = nil
                } catch {
                    report = before
                    engineError = Self.errorText(error, doing: .change)
                }
            }
        }
    }

    private func stop() async {
        guard let control = session.control else { return }
        stopping = true
        defer { stopping = false }
        do {
            stopNote = try await control.stop() ? String(localized: "Chief stopped.") : String(localized: "Chief had nothing running.")
        } catch {
            stopNote = Self.errorText(error, doing: .stop)
        }
    }

    #if DEBUG
    /// The raw errors behind the plain sentences (DEBUG builds only).
    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Engine read", value: session.engineError.map { String(describing: $0) } ?? "OK")
            LabeledContent("Report", value: session.engineReportIsCurrent ? "Current" : (report == nil ? "None" : "Kept from earlier"))
            if let failure = session.lastTurnFailure {
                LabeledContent("Last failed turn", value: failure.detail)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .accessibilityIdentifier("chief.settings.diagnostics")
        .listRowBackground(ChiefInfoGeometry.card)
    }
    #endif

    // MARK: Labels

    /// The model turns run on, by name: the chosen one, else what the
    /// default resolves to; nil when the report names none.
    static func currentModelName(_ report: ChiefEngineReport) -> String? {
        if let chosen = report.choice.model, chosen != "default" { return report.modelName(chosen) ?? chosen }
        if let name = report.resolvedDefaultName { return name }
        guard let model = report.engine.model, model != "default" else { return nil }
        return report.modelName(model) ?? model
    }

    static func defaultLabel(_ current: String?) -> String {
        current.map { String(localized: "Default (\($0))") } ?? String(localized: "Default")
    }

    /// The model picker's default item names what it resolves to (F1):
    /// "Default (GPT-6.1 Sol)" from a Mac that resolves it (#20531), plain
    /// "Default" from an older Mac.
    static func defaultModelLabel(_ report: ChiefEngineReport) -> String {
        defaultLabel(report.resolvedDefaultName)
    }

    enum Action { case change, stop }

    /// A sentence for the page (F2); the raw error goes to the log only.
    /// Refusals the Mac explains (no Chief, not allowed, a bad avatar) keep
    /// their own sentence; anything else says what did not happen.
    static func errorText(_ error: any Error, doing action: Action) -> String {
        log.error("chief settings \(String(describing: action), privacy: .public): \(String(describing: error), privacy: .public)")
        if let control = error as? ChiefControlError {
            switch (control.code, control.reason) {
            case ("origin.forbidden", _), (_, "not_configured"?), (_, "unavailable"?): return control.description
            case ("invalid_avatar", _), (_, "invalid_avatar"?): return String(localized: "Use an emoji or one or two letters.")
            case ("unknown_harness", _), (_, "unknown_harness"?): return String(localized: "This Mac can't run Chief on that harness.")
            default: break
            }
        }
        if let backend = error as? ConversationBackendError, backend.code == -1 { return backend.message }
        // No answer from the Mac is not Chief refusing (the old copy blamed Chief for a dropped link).
        switch ChiefEngineProblem(error) {
        case .macUnreachable: return String(localized: "Your Mac didn't answer. Check that it's on and connected, then try again.")
        case .chiefBusy: return String(localized: "Chief on your Mac is busy and didn't answer in time. Try again.")
        default: break
        }
        return switch action {
        case .change: String(localized: "Chief on your Mac didn't take the change. Try again.")
        case .stop: String(localized: "Chief on your Mac didn't stop. Try again.")
        }
    }

    static func harnessName(_ id: String) -> String {
        switch id {
        case "claude": "Claude"
        case "codex": "Codex"
        case "claude-cr": "Claude (CodeRouter)"
        default: id
        }
    }

    static func effortName(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    /// A recent turn's first line: the model's display name, else the
    /// harness's ("Claude", "Codex"); never a raw id.
    static func turnTitle(_ turn: ChiefEngineReport.Turn, in report: ChiefEngineReport?) -> String {
        if let name = report?.modelName(turn.model) { return name }
        if let harness = turn.harness { return harnessName(harness) }
        return String(localized: "Turn")
    }

    /// "Failed · 2 min 57 s · 3 tools · $0.04".
    static func turnLine(_ turn: ChiefEngineReport.Turn) -> String {
        var parts: [String] = []
        if let status = turn.status { parts.append(statusName(status)) }
        if let ms = turn.ms { parts.append(durationText(milliseconds: ms)) }
        if let tools = turn.tools, tools > 0 {
            parts.append(tools == 1 ? String(localized: "1 tool") : String(localized: "\(tools) tools"))
        }
        if let cost = turn.costUSD { parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))) }
        return parts.joined(separator: " · ")
    }

    /// The brain's turn status (`ok`, `error`, `stopped`, ...) in words.
    static func statusName(_ status: String) -> String {
        switch status.lowercased() {
        case "ok", "done", "completed", "complete", "success", "end": String(localized: "Completed")
        case "error", "failed", "failure": String(localized: "Failed")
        case "stopped", "interrupted", "cancelled", "canceled", "aborted": String(localized: "Stopped")
        case "running": String(localized: "Running")
        default: status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    /// "2 min 57 s", "45 s", "1 h 2 min".
    static func durationText(milliseconds: Double) -> String {
        let seconds = Int((milliseconds / 1000).rounded())
        let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        if h > 0 { return m > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(h) h") }
        if m > 0 { return s > 0 ? String(localized: "\(m) min \(s) s") : String(localized: "\(m) min") }
        return String(localized: "\(s) s")
    }
}

/// Messages' contact details, measured from MobileSMS on iOS 26.5
/// (CmuxConversation's `ConversationDetailsHeaderGeometry`, which is not a
/// public product, so its numbers are repeated here): an 80 pt avatar whose
/// top is the status bar's bottom, the 28 pt bold title's line box 84 pt
/// below the avatar's top, 48 pt quick actions 20 pt apart and 16 pt under
/// the title, and 20 pt from them to the first card.
enum ChiefInfoGeometry {
    static let avatarSize: CGFloat = 80
    static let titleTopFromAvatar: CGFloat = 84
    static let quickActionSize: CGFloat = 48
    static let quickActionSpacing: CGFloat = 20
    static let quickActionsBelowTitle: CGFloat = 16
    static let sectionGap: CGFloat = 20
    /// Messages' cards: the secondary background on the plain one.
    static let card = Color(uiColor: .secondarySystemBackground)
    /// What the inset grouped list adds between a section header and its
    /// first row (measured on iOS 26.5).
    static let listGapAfterHeader: CGFloat = 0
    /// Scrolled this far, the cards reach the bar and its edge blur returns.
    static let edgeEffectAfter: CGFloat = 40
}

/// Messages' details backdrop: the system background (white, or black in
/// dark mode) under cards in the secondary background, with a soft wash of
/// the contact's color behind the header. Chief's color is its monogram's.
struct ChiefInfoBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            Ellipse()
                .fill(monogramGradient)
                .frame(width: 520, height: 360)
                .offset(y: -150)
                .blur(radius: 90)
                .opacity(scheme == .dark ? 0.9 : 0.55)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// One of Messages' round quick actions (CommunicationDetails
/// QuickActionView): a 48 pt circle in the tertiary fill with the filled
/// glyph, unlabeled as in Messages (VoiceOver reads its name); an action
/// that cannot run now dims its glyph.
struct ChiefQuickAction: View {
    let symbol: String
    let title: String
    let enabled: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(uiColor: .tertiarySystemFill))
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle(enabled ? Color.primary : Color(uiColor: .tertiaryLabel))
                }
            }
            .frame(width: ChiefInfoGeometry.quickActionSize, height: ChiefInfoGeometry.quickActionSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(busy ? Text("In progress") : Text(""))
    }
}

/// Reports the window's top safe inset (the status bar), which a pushed
/// page's own safe area hides under the navigation bar, and keeps the back
/// swipe on: SwiftUI turns the stack's pop gestures off while the screen
/// under this one (the Chief conversation) hides the bar, and does not
/// always turn them on again for a page pushed over it, nor when Edit pops
/// back to it. A child view controller gets each appearance once the
/// transition has finished, after SwiftUI's own bar updates.
struct WindowSafeTopReader: UIViewControllerRepresentable {
    let report: (CGFloat) -> Void

    func makeUIViewController(context: Context) -> Probe {
        let probe = Probe()
        probe.report = report
        return probe
    }

    func updateUIViewController(_ probe: Probe, context: Context) { probe.report = report }

    final class Probe: UIViewController {
        var report: ((CGFloat) -> Void)?
        private var reported: CGFloat = -1

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            send()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableBackSwipe()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            send()
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            send()
        }

        private func send() {
            guard let top = view.window?.safeAreaInsets.top, top != reported else { return }
            reported = top
            // Not inside SwiftUI's update of this view.
            Task { @MainActor [report] in report?(top) }
        }

        /// Only while this page is the settled top of its stack, with nothing over it.
        private func enableBackSwipe() {
            guard view.window != nil, let navigation = navigationController, navigation.viewControllers.count > 1,
                  navigation.transitionCoordinator == nil, navigation.presentedViewController == nil,
                  let top = navigation.topViewController else { return }
            var ancestor: UIViewController? = self
            while let current = ancestor, current !== top { ancestor = current.parent }
            guard ancestor != nil else { return }
            navigation.interactivePopGestureRecognizer?.isEnabled = true
            navigation.interactiveContentPopGestureRecognizer?.isEnabled = true
        }
    }
}

/// Messages' Edit: Chief's name, and its avatar on a Mac that reads and
/// sets it, each a value on the right that opens a one-field page with Save.
struct ChiefIdentityEditor: View {
    let session: ChiefSession

    private var name: String { session.title ?? session.identity.title }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ChiefFieldEditor(title: String(localized: "Name"), value: name, footer: nil) { value in
                        try await session.rename(value)
                    }
                } label: {
                    LabeledContent("Name", value: name)
                }
                .accessibilityIdentifier("chief.settings.name")
                if let report = session.engineReport, report.avatarSupported {
                    NavigationLink {
                        ChiefFieldEditor(title: String(localized: "Avatar"), value: report.avatar ?? "",
                                         footer: String(localized: "An emoji or one or two letters. Leave it empty for \(ChiefIdentity.defaultAvatar)."), allowsEmpty: true) { value in
                            try await setAvatar(value)
                        }
                    } label: {
                        LabeledContent("Avatar", value: session.avatar)
                    }
                    .accessibilityIdentifier("chief.settings.avatar")
                }
            } footer: {
                Text("Changes apply on your Mac and every device.")
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chief.settings.identity")
    }

    /// Sets the avatar on the Mac (`chief.engine.set` `avatar`); empty is the default.
    private func setAvatar(_ value: String) async throws {
        guard let control = session.control else {
            throw ConversationBackendError(code: -1, message: String(localized: "Chief isn't connected to a Mac"))
        }
        session.adopt(try await control.setEngine(avatar: value))
    }
}

/// One field of Chief's identity (Name, Avatar) on its own page, as
/// Settings edits a value: the field, Save in the bar, and the Mac's
/// refusal in the footer when it does not take the change.
struct ChiefFieldEditor: View {
    let title: String
    let original: String
    let footer: String?
    /// The name may not be empty; the avatar may (it clears to the default).
    let allowsEmpty: Bool
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, value: String, footer: String?, allowsEmpty: Bool = false,
         save: @escaping (String) async throws -> Void) {
        self.title = title
        original = value
        self.footer = footer
        self.allowsEmpty = allowsEmpty
        self.save = save
        _value = State(initialValue: value)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { trimmed != original && (allowsEmpty || !trimmed.isEmpty) && !saving }

    var body: some View {
        Form {
            Section {
                TextField(title, text: $value)
                    .focused($focused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit { if canSave { Task { await commit() } } }
                    .accessibilityIdentifier("chief.settings.field")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let footer {
                    Text(footer)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await commit() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("chief.settings.save")
                }
            }
        }
        .onAppear { focused = true }
    }

    private func commit() async {
        saving = true
        defer { saving = false }
        do {
            try await save(trimmed)
            dismiss()
        } catch {
            self.error = ChiefSettingsView.errorText(error, doing: .change)
        }
    }
}
#endif
