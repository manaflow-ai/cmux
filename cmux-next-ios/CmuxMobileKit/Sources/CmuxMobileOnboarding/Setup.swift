#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit
import UserNotifications

private let theme = CmuxMobileTheme.standard

/// First-run setup after sign-in (SPEC 5.5). Each step is a full page pushed in
/// a `NavigationStack`; progress is implicit.
public struct SetupFlow: View {
    /// A setup step. `createTeam` is pushed from the space choice, never planned.
    public enum Step: Hashable, Sendable {
        case team, pairMac, notifications, createTeam
    }

    let steps: [Step]
    let auth: CmuxMobileAuthModel
    let store: AppStore
    /// The user picked a team: live data moves to it.
    let teamPicked: (String) -> Void
    /// The user picked their personal space: live data moves to it.
    let personalPicked: () -> Void
    /// The user created a team: live data moves to it.
    let teamCreated: (AppStore.AccountTeam) -> Void
    /// Signs out to Welcome, to start over with another account.
    let signOut: () -> Void
    let finish: () -> Void
    @State private var path: [Step] = []
    @State private var confirmsSignOut = false

    public init(
        steps: [Step], auth: CmuxMobileAuthModel, store: AppStore,
        signOut: @escaping () -> Void = {},
        teamPicked: @escaping (String) -> Void = { _ in },
        personalPicked: @escaping () -> Void = {},
        teamCreated: @escaping (AppStore.AccountTeam) -> Void = { _ in },
        finish: @escaping () -> Void
    ) {
        self.steps = steps
        self.auth = auth
        self.store = store
        self.teamPicked = teamPicked
        self.personalPicked = personalPicked
        self.teamCreated = teamCreated
        self.signOut = signOut
        self.finish = finish
    }

    /// Whether setup should ask for notifications: only a build that can
    /// receive pushes from the Macs, and only while the system has not asked.
    /// (Chief's local alerts ask in context, on the first message to Chief.)
    public static func asksForNotifications() async -> Bool {
        guard BuildCapabilities.current.push else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let first = steps.first { page(first) } else { theme.colors.bg.color.ignoresSafeArea() }
            }
            // On every setup page, loading and failure included: who is signed
            // in, and a way back to Welcome to start over. Inset per page: on
            // the stack, pushed pages did not leave room for it and the footer
            // sat over the bottom of Continue (terminal review round 4).
            .safeAreaInset(edge: .bottom, spacing: 0) { accountFooter }
            .navigationDestination(for: Step.self) { step in
                page(step).safeAreaInset(edge: .bottom, spacing: 0) { accountFooter }
            }
        }
        .tint(theme.colors.label.color)
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            switch DemoDirector.shared.command {
            case .setupSignOut: confirmsSignOut = true
            case .setupConfirmSignOut: confirmsSignOut = false; signOut()
            default: break
            }
        }
        #endif
        #if DEBUG
        // A screen demo (`-CmuxMobileDemo chat-feed`, …) on a fresh install skips setup in
        // Personal, so its driver never waits here. The onboarding demo drives setup itself.
        .task {
            guard let demo = Self.launchDemoName, demo != "onboarding" else { return }
            if steps.contains(.team) {
                store.selectPersonalSpace()
                personalPicked()
            }
            finish()
        }
        #endif
        .confirmationDialog("Sign out and start over?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                theme.haptics.warning()
                signOut()
            }
        } message: {
            Text("You can sign in again with this or another account.")
        }
    }

    #if DEBUG
    private static var launchDemoName: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CmuxMobileDemo"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        return DeveloperOptions.launchDemo
    }
    #endif

    private var accountFooter: some View {
        HStack(spacing: 6) {
            if let email = auth.user?.email, !email.isEmpty {
                Text("Signed in as \(email)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
            }
            Button("Sign out") { confirmsSignOut = true }
                .fontWeight(.semibold)
                .foregroundStyle(theme.colors.label)
                .accessibilityIdentifier("setup.sign-out")
        }
        .font(theme.type.meta)
        .foregroundStyle(theme.colors.label2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(theme.colors.bg.color.ignoresSafeArea())
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .team:
            TeamStep(auth: auth, store: store, picked: teamPicked, personal: personalPicked,
                     create: { path.append(.createTeam) }, next: { advance(from: .team) })
        case .createTeam:
            CreateTeamPage(auth: auth, created: teamCreated) {
                // Back from the next page returns to the choice, not the form.
                path.removeAll { $0 == .createTeam }
                advance(from: .team)
            }
        case .pairMac: PairMacStep(email: auth.user?.email, store: store, next: { advance(from: .pairMac) })
        case .notifications: NotificationsStep(next: { advance(from: .notifications) })
        }
    }

    private func advance(from step: Step) {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            finish()
            return
        }
        path.append(steps[index + 1])
    }
}

/// A setup page (design spec, section 8): a 40 pt symbol or the welcome's art,
/// a `title2` semibold title, the content, then the actions 24 pt above the
/// account footer.
private struct SetupPage<Header: View, Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header().frame(maxWidth: .infinity)
                    Text(title)
                        .font(theme.type.sidebarTitle)
                        .foregroundStyle(theme.colors.label)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                    content()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
                .padding(.top, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center, for: .alignment)
            VStack(spacing: 10) { actions() }
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .background(theme.colors.bg.color.ignoresSafeArea())
    }
}

extension SetupPage where Header == SetupSymbol {
    init(symbol: String, title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, header: { SetupSymbol(name: symbol) }, content: content, actions: actions)
    }
}

private struct SetupSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 40, weight: .regular))
            .foregroundStyle(theme.colors.label)
    }
}

private struct ExplainerRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 22)
                .foregroundStyle(theme.colors.label)
            Text(text)
                .font(theme.type.body)
                .foregroundStyle(theme.colors.label)
        }
        .padding(.vertical, 8)
    }
}

/// "Choose a space" (design spec, section 5): the title and Personal from the
/// first frame, the account's teams under it (skeleton rows while they load,
/// an inline retry if they can't), and "Create a team" once they're known.
/// An empty list before the answer is "not loaded", never "no teams", so
/// "Create a team" never shows as a placeholder.
private struct TeamStep: View {
    let auth: CmuxMobileAuthModel
    let store: AppStore
    let picked: (String) -> Void
    let personal: () -> Void
    let create: () -> Void
    let next: () -> Void
    @State private var isRetrying = false
    /// "Create a team" arrives 0.1 s after the team rows (its own fade: a
    /// nested transition would not run inside the rows' insertion).
    @State private var showsCreate = false

    private enum Phase: Hashable { case loading, failed, loaded }

    private var phase: Phase {
        switch auth.teamList.phase {
        case .loading: .loading
        case .failed: .failed
        case .loaded: .loaded
        }
    }

    /// The account's teams, the personal space aside (it has its own row).
    private var teams: [Team] { store.teams.filter { !$0.id.hasPrefix("personal-") } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a space")
                        .font(theme.type.sidebarTitle)
                        .foregroundStyle(theme.colors.label)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your Macs appear in their signed-in space.")
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.top, 12)
                .padding(.bottom, 16)
                VStack(spacing: 0) {
                    row(action: pickPersonal) { personalRow }
                        .accessibilityIdentifier("setup.teams.personal")
                    ZStack(alignment: .top) {
                        switch phase {
                        case .loading:
                            SkeletonList(rows: 2, leadingSquare: theme.metrics.teamAvatar, delay: .zero)
                                .transition(.opacity)
                                .accessibilityIdentifier("setup.teams.loading")
                        case .failed:
                            failedRow
                                .transition(.opacity)
                                .accessibilityIdentifier("setup.teams.failed")
                        case .loaded:
                            VStack(spacing: 0) {
                                ForEach(teams) { team in
                                    let presence = team.macDots()
                                    row(action: { pick(team) }) {
                                        SidebarTeamRow(
                                            name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji,
                                            transparent: team.appearance.isTransparent,
                                            dots: presence.dots, overflow: presence.overflow,
                                            onlineCount: team.listedMacs.filter(\.isOnline).count, isSelected: false
                                        )
                                    }
                                }
                                row(action: create) { createRow }
                                    .opacity(showsCreate ? 1 : 0)
                                    .allowsHitTesting(showsCreate)
                                    .accessibilityIdentifier("setup.teams.create")
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .animation(theme.motion.smooth.animation, value: phase)
            }
        }
        .onChange(of: phase, initial: true) { _, phase in
            guard phase == .loaded else {
                showsCreate = false
                return
            }
            withAnimation(theme.motion.smooth.animation.delay(0.1)) { showsCreate = true }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.colors.bg.color.ignoresSafeArea())
        .accessibilityIdentifier("setup.teams.choose")
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            if case .setupPickTeam(let index) = DemoDirector.shared.command {
                if index == 0 { pickPersonal() } else if teams.indices.contains(index - 1) { pick(teams[index - 1]) }
            }
        }
        #endif
    }

    private func row<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .padding(.horizontal, theme.metrics.selectedRowInset)
    }

    /// Personal needs only the signed-in user, so it is never a skeleton.
    private var personalRow: some View {
        let space = store.teams.first { $0.id.hasPrefix("personal-") }
        let presence = space?.macDots() ?? (dots: [], overflow: 0)
        return HStack(spacing: 12) {
            // The personal space looks the same here as in the sidebar: its
            // own avatar once the account has it, a person until then.
            if let space {
                TeamAvatar(name: space.name, colorHex: space.appearance.colorHex, emoji: space.appearance.emoji,
                           size: theme.metrics.teamAvatar, transparent: space.appearance.isTransparent)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.colors.label)
                    .frame(width: theme.metrics.teamAvatar, height: theme.metrics.teamAvatar)
                    .background(theme.colors.fillSelected, in: .rect(cornerRadius: theme.metrics.teamAvatarRadius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Personal")
                    .font(theme.type.rowTitle)
                    .foregroundStyle(theme.colors.label)
                HStack(spacing: 8) {
                    Text("Just you").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                    if !presence.dots.isEmpty { MacPresenceDots(dots: presence.dots, overflow: presence.overflow) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.metrics.sideMargin - theme.metrics.selectedRowInset)
        .frame(minHeight: theme.metrics.teamRowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var createRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.colors.label)
                .frame(width: theme.metrics.teamAvatar, height: theme.metrics.teamAvatar)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.metrics.teamAvatarRadius, style: .continuous)
                        .strokeBorder(theme.colors.separator, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            Text("Create a team")
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.metrics.sideMargin - theme.metrics.selectedRowInset)
        .frame(minHeight: theme.metrics.teamRowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// A failed team list doesn't block setup: Personal stays selectable.
    private var failedRow: some View {
        HStack(spacing: 12) {
            Text("Couldn't load your teams.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
            Spacer(minLength: 0)
            if isRetrying {
                ProgressView().controlSize(.small)
            } else {
                Button("Retry", action: retry)
                    .font(theme.type.rowSubtitle.weight(.semibold))
                    .foregroundStyle(theme.colors.label)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .frame(minHeight: theme.metrics.teamRowHeight)
    }

    private func retry() {
        isRetrying = true
        Task {
            await auth.retryTeams()
            isRetrying = false
        }
    }

    private func pickPersonal() {
        theme.haptics.selection()
        // Picking Personal must leave Personal active: the store selects it
        // here when it lists it (with no live coordinator, nothing else
        // would, and the previous team stayed active), and the live
        // coordinator adds it when it isn't listed yet.
        store.selectPersonalSpace()
        personal()
        next()
    }

    private func pick(_ team: Team) {
        store.selectTeam(team.id)
        theme.haptics.selection()
        picked(team.id)
        Task { await auth.selectTeam(team.id) }
        next()
    }
}

/// "Create your team", pushed from the space choice (Back returns to it).
private struct CreateTeamPage: View {
    let auth: CmuxMobileAuthModel
    let created: (AppStore.AccountTeam) -> Void
    let next: () -> Void
    @State private var name = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        SetupPage(symbol: "person.2", title: "Create your team") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Team name", text: $name)
                    // Names are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(theme.type.body)
                    .cmuxMobileInputField()
                    .onSubmit(create)
                if let error { Text(error).font(theme.type.meta).foregroundStyle(theme.colors.dangerText) }
            }
        } actions: {
            PrimaryCapsule("Create team", isLoading: isCreating) { create() }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .accessibilityIdentifier("setup.teams.create-page")
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !isCreating else { return }
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let team = try await auth.createTeam(named: name)
                created(team)
                theme.haptics.success()
                next()
            } catch {
                self.error = CmuxMobileAuthModel.message(for: error) ?? "Couldn't create the team."
                theme.haptics.error()
            }
        }
    }
}

/// "Connect your Mac": no pairing code. A Mac signed in to the same account
/// with iPhone connections allowed appears by itself, in whichever team or
/// personal space it uses: live discovery moves the phone to that team, the
/// status line flips, and Continue appears. The welcome's art waits with it:
/// a 1.5 s faint thread and dot every 2.4 s, then the ride and the chevron's bloom
/// when the Mac shows up.
private struct PairMacStep: View {
    let email: String?
    let store: AppStore
    let next: () -> Void
    /// When the Mac showed up (the art's ride starts then).
    @State private var foundAt: Date?
    /// A Mac was already online when the page opened: the art starts settled.
    @State private var foundAtStart = false
    @State private var waitingSince = Date.now
    /// The ride and bloom are playing.
    @State private var riding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onlineMac: String? {
        store.activeTeam?.macs.first(where: \.isOnline)?.name
    }

    var body: some View {
        SetupPage(title: "Connect your Mac") {
            art
        } content: {
            ConnectMacSteps(email: email, onlineMac: onlineMac, teamName: store.teams.count > 1 ? store.activeTeam?.name : nil,
                            noMacsForAccount: store.accountMacCount == 0)
        } actions: {
            // One button for both states (D6): see `PairMacCallToAction`. Its
            // label and style change in place; nothing is inserted or removed,
            // so a press in flight when the Mac shows up still fires.
            let cta = PairMacCallToAction(macOnline: onlineMac != nil)
            Button { perform(PairMacCallToAction(macOnline: onlineMac != nil).action) } label: {
                Text(LocalizedStringKey(cta.title))
            }
            .buttonStyle(PairMacCTAStyle(emphasis: cta.emphasis))
            .accessibilityIdentifier(PairMacCallToAction.accessibilityIdentifier)
            .animation(theme.motion.snappy.animation, value: cta.emphasis)
        }
        .onAppear { foundAtStart = onlineMac != nil }
        .onChange(of: onlineMac != nil) { _, found in
            guard found else {
                // The Mac went away again: back to waiting.
                foundAt = nil
                foundAtStart = false
                waitingSince = .now
                return
            }
            guard foundAt == nil, !foundAtStart else { return }
            foundAt = .now
            riding = true
            theme.haptics.success()
        }
        .task(id: foundAt) {
            // Stops the art's clock once the bloom has settled: a bounded
            // animation length, not synchronization.
            guard foundAt != nil else { return }
            try? await Task.sleep(for: .seconds(WelcomeArt.introDuration - WelcomeArt.rideStart + 0.1))
            if !Task.isCancelled { riding = false }
        }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { if DemoDirector.shared.command == .setupNotNow { next() } }
        #endif
    }

    /// Resolved at touch-up from the state then; every state advances.
    private func perform(_ action: PairMacCallToAction.Action) {
        switch action {
        case .advance: next()
        }
    }

    /// The settled devices while waiting (Reduce Motion: no pulses), then
    /// the ride and the bloom from the welcome's intro.
    private var art: some View {
        let settled = foundAtStart || (reduceMotion && onlineMac != nil)
        let waiting = !settled && foundAt == nil && !reduceMotion
        // Frames only while something moves: every display frame during the
        // ride, the 1.5 s pulse of each 2.4 s wait cycle (none in the 0.9 s
        // gap), one frame when settled (S6, `ConnectMacArtSchedule`).
        let schedule = ConnectMacArtSchedule(mode: riding ? .riding
            : waiting ? .pulses(since: waitingSince, period: 2.4, active: WelcomeArt.IdleStyle.waiting.duration)
            : .still)
        return TimelineView(schedule) { context in
            let t: Double = {
                if settled { return .infinity }
                if let foundAt { return WelcomeArt.rideStart + context.date.timeIntervalSince(foundAt) }
                return WelcomeArt.rideStart
            }()
            let idle: Double? = {
                guard waiting else { return nil }
                let u = context.date.timeIntervalSince(waitingSince).truncatingRemainder(dividingBy: 2.4)
                return u < WelcomeArt.IdleStyle.waiting.duration ? u : nil
            }()
            WelcomeArt(t: t, idle: idle, idleStyle: .waiting, width: 200)
        }
    }
}

/// The pair-Mac step's button in both states (D6): the primary capsule when a
/// Mac is online, plain text while waiting. One view tree in both, with the
/// capsule's fill faded rather than removed and a full-width, 52 pt hit shape
/// in both states, so a state change never replaces or shrinks the hit target
/// under a finger.
private struct PairMacCTAStyle: ButtonStyle {
    let emphasis: PairMacCallToAction.Emphasis

    func makeBody(configuration: Configuration) -> some View {
        let primary = emphasis == .primary
        let pressed = configuration.isPressed
        configuration.label
            .font(theme.type.cta)
            .foregroundStyle(primary ? theme.colors.onAccent : theme.colors.label)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, theme.metrics.ctaInlinePadding)
            // Grows with Dynamic Type instead of clipping its label.
            .padding(.vertical, 12)
            .frame(minHeight: CmuxMobileCapsuleSize.large.height)
            .background(theme.colors.accent.color.opacity(primary ? 1 : 0), in: .capsule)
            .contentShape(.rect)
            .opacity(pressed ? 0.85 : 1)
            .scaleEffect(primary && pressed ? 0.98 : 1)
            .animation(theme.motion.snap.animation, value: pressed)
    }
}

/// Notification priming before the system prompt. Planned only for builds
/// that can receive pushes, while the system has not asked yet.
private struct NotificationsStep: View {
    let next: () -> Void

    var body: some View {
        SetupPage(symbol: "bell.badge", title: "Know when an agent needs you") {
            VStack(alignment: .leading, spacing: 4) {
                ExplainerRow(symbol: "questionmark.bubble", text: "Questions and permission requests")
                ExplainerRow(symbol: "checkmark.circle", text: "Finished tasks")
                ExplainerRow(symbol: "exclamationmark.triangle", text: "Errors that stop an agent")
            }
            .frame(maxWidth: 340, alignment: .leading)
        } actions: {
            PrimaryCapsule("Turn on notifications") {
                Task {
                    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                    // The token goes to the service once this phone is registered with its team.
                    if granted, BuildCapabilities.current.push { UIApplication.shared.registerForRemoteNotifications() }
                    next()
                }
            }
            TextCTA("Not now", action: next)
        }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { if DemoDirector.shared.command == .setupNotNow { next() } }
        #endif
    }
}
#endif
