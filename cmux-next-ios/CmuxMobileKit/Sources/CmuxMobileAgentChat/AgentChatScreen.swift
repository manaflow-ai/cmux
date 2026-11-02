#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileArtifacts
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
import CmuxMobileModel
import SwiftUI
import UIKit

/// View state of one open agent chat, shared by its transcript and its
/// bottom stack. The pushed `AgentChatScreen` owns one; a workspace tab
/// (CmuxTabsKit) keeps one per tab so the transcript (the tab's page) and
/// the composer (the tab's accessory row above the toolbar) are separate
/// views that act as one screen.
@MainActor
@Observable
public final class AgentChatSurface {
    public var text = ""
    /// The transcript holds its rows as they are (the page is shown as a
    /// small card on the tab grid): streamed changes wait and apply in one
    /// reload when this goes back to false, or on `refreshHeldTranscript()`.
    public var holdsTranscript = false
    /// Bumped to apply what arrived while held, in one reload (the grid's
    /// once-a-second card refresh).
    private(set) var heldRefresh = 0
    public func refreshHeldTranscript() { heldRefresh &+= 1 }
    var attachments: [AgentAttachment] = []
    /// The transcript's scroll position. Writes that change nothing are
    /// dropped: SwiftUI writes the resolved position back through the
    /// binding, and an unconditional invalidation there can feed back into
    /// another scroll request without end (seen with live sessions).
    var position: ScrollPosition {
        get {
            access(keyPath: \.position)
            return storedPosition
        }
        set {
            guard newValue != storedPosition else { return }
            withMutation(keyPath: \.position) { storedPosition = newValue }
        }
    }
    @ObservationIgnored private var storedPosition = ScrollPosition(edge: .bottom)
    public internal(set) var following = true
    var showJump = false
    var diffRoute: DiffRoute?
    /// Subagents, a subagent, checkpoints or the handoff, pushed over the chat.
    public var parityRoute: AgentParityRoute?
    /// The session's artifacts browser (a sheet).
    public var showArtifacts = false
    /// `/status`'s sheet while it is up.
    var showStatus = false
    /// The earlier prompt in Edit and Resend's sheet (nil: closed).
    var editingEarlier: EarlierPromptEdit?
    /// What the chat's workspace tab does with it (fork into a new tab); nil for a chat
    /// outside a workspace tab, which then offers neither `/fork` nor an earlier prompt's edit.
    public var tabActions: AgentChatTabActions?

    /// Edit and Resend on an earlier prompt: its sheet, when the chat can fork before it.
    func editEarlier(_ turn: AgentTurn, store: AgentChatStore) {
        guard tabActions != nil, let seq = store.editForkSeq(for: turn) else { return }
        composerFocused = false
        editingEarlier = EarlierPromptEdit(turnID: turn.id, throughSeq: seq, original: turn.prompt)
    }

    /// A cmux command typed in the composer (`/status`, `/fork`, `/continue [harness]`): run
    /// here; nil when it ran (or opened its screen), else the refusal to show (the draft stays).
    func run(_ command: CmuxSlashCommand, args: String, store: AgentChatStore) async -> String? {
        let canFork = tabActions != nil
        switch command {
        case .status:
            showStatus = true
            return nil
        case .fork:
            if let refusal = command.refusal(args: args, canFork: canFork, isRunning: store.isRunning, targets: nil) { return refusal }
            await tabActions?.fork()
            return nil
        case .continue:
            if let refusal = command.refusal(args: args, canFork: canFork, isRunning: store.isRunning, targets: nil) { return refusal }
            guard !args.isEmpty else {
                parityRoute = .handoff
                return nil
            }
            let targets: [AgentHandoffTarget]
            do {
                targets = try await store.source.handoffTargets()
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            if let refusal = command.refusal(args: args, canFork: canFork, isRunning: store.isRunning, targets: targets) { return refusal }
            guard let target = CmuxSlashCommand.target(args, in: targets) else { return nil }
            if let reason = target.unavailableReason { return reason }
            parityRoute = .handoffTo(target)
            return nil
        }
    }
    /// Find in Chat while its bar is up (nil: closed).
    public var find: AgentChatFind?
    /// Asks the find bar's field for the keyboard (it takes it when the bar opens).
    var findFieldFocused = false

    /// Find in Chat: opens the bar with its field focused (the composer gives the keyboard up).
    public func openFind() {
        if find == nil { find = AgentChatFind() }
        composerFocused = false
        findFieldFocused = true
    }

    /// Done: the bar closes and the marks go.
    public func closeFind() {
        find = nil
        findFieldFocused = false
    }

    /// Scrolls the transcript to the find bar's current match: the top of the rendered block
    /// that holds it (a prompt bubble, or one paragraph, list, code card or table of an answer).
    func revealFindMatch() {
        guard let match = find?.currentMatch else { return }
        scroller?.revealFindBlock(match.block, position: match.position, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    public let artifacts = ArtifactsBrowserState()
    // DEBUG demo hooks for the parity screens (the screens act on them through their own paths).
    var demoCheckpointRestore: String?
    var demoConfirmRestore = 0
    var demoHandoffTarget: String?
    var demoHandoffFill: String?
    var demoHandoffStart = 0
    @ObservationIgnored private var lastDemoSerial = -1
    var replyInsteadOfPermission = false
    /// A permission arrived while the person was typing: the composer stays
    /// (the draft is a follow-up, not an answer) and the card offers the choices.
    var permissionDeferred = false
    /// Whether the permission bar is out of the composer's place.
    var permissionBarHidden: Bool { replyInsteadOfPermission || permissionDeferred }

    /// Brings the permission choices back in the composer's place.
    func showPermissionChoices() {
        replyInsteadOfPermission = false
        permissionDeferred = false
        composerFocused = false
    }
    /// Mirrors the composer's focus (the composer's `@FocusState` follows it).
    public var composerFocused = false

    /// Edit and Resend from a user bubble: the message goes into the composer to edit and
    /// is sent from there. Returns false, changing nothing, while the composer holds a
    /// draft (the bubble asks before replacing it).
    func editAndResend(_ turn: AgentTurn, store: AgentChatStore) -> Bool {
        guard let prompt = store.editAndResend(turn, draft: text) else { return false }
        loadForEditing(prompt, permissionPending: store.pendingPermission != nil)
        return true
    }

    /// Puts a message in the composer, focused. With permission choices up, the composer
    /// takes their place as a follow-up, as for a draft typed before the permission arrived,
    /// never as "Reply instead", which would answer the request (an open "Reply instead" ends).
    func loadForEditing(_ prompt: String, permissionPending: Bool) {
        text = prompt
        replyInsteadOfPermission = false
        if permissionPending { permissionDeferred = true }
        composerFocused = true
    }
    /// Screen y of the top of the floating bottom stack (tab mode), so the
    /// transcript's bottom margin follows the composer and the keyboard.
    public internal(set) var bottomStackTop: CGFloat?
    /// The bottom stack's height and bottom edge in screen space, so a
    /// transcript whose stack is drawn elsewhere (a workspace tab) can place
    /// it from the keyboard layout guide in the keyboard's own animation.
    public internal(set) var stackHeight: CGFloat?
    public internal(set) var stackMaxY: CGFloat?
    /// Window y the bottom stack may not rise above: under the transcript's header and,
    /// for the pushed chat, inside the dock's host. The transcript sets it as it lays
    /// out; the composer's slash-command list scrolls inside the room below it.
    var stackCeiling: CGFloat?
    /// The live transcript's scroll view (jump to bottom, demos).
    @ObservationIgnored weak var scroller: (any ChatTranscriptScrolling)?
    /// The bottom stack's height as drawn, once per frame while it animates
    /// (the transcript's inset follows it in the same frame).
    @ObservationIgnored var stackHeightFrame: ((CGFloat) -> Void)?
    @ObservationIgnored var drawnStackHeight: CGFloat?
    /// Rows the person opened or closed (the transcript's cells are reused).
    let disclosures = ChatDisclosures()

    public init() {}

    struct DiffRoute: Identifiable, Hashable {
        let changes: DiffChangeSet
        let fileID: String?
        var id: String { changes.id + (fileID ?? "") }
    }

    /// Opens the edits this agent made in the loaded chat history (title menu
    /// "Agent edits"). Not the working tree: other changes on the Mac, and
    /// edits older than the loaded history, are not included.
    public func openAllChanges(of store: AgentChatStore) {
        guard let changes = Self.agentEdits(of: store) else { return }
        diffRoute = DiffRoute(changes: changes, fileID: nil)
    }

    /// Each file the agent edited, once, in first-edit order, built from every edit to it
    /// across the loaded turns; nil when there are none.
    static func agentEdits(of store: AgentChatStore) -> DiffChangeSet? {
        let files = AgentTurn.diffFiles(store.turns.flatMap(\.edits))
        guard !files.isEmpty else { return nil }
        return DiffChangeSet(id: "session", title: "Agent Edits", subtitle: "Edits in this chat", files: files)
    }

    /// Whether the chat has agent edits to open.
    public static func hasAgentEdits(_ store: AgentChatStore) -> Bool {
        store.hasAgentEdits
    }

    public func scrollToBottom(animated: Bool = true) {
        following = true
        if let scroller {
            scroller.scrollTranscript(toTop: false, animated: animated)
        } else if animated, !UIAccessibility.isReduceMotionEnabled {
            withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: .bottom) }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    /// The transcript as Markdown (Share transcript).
    public static func transcriptText(_ store: AgentChatStore) -> String {
        store.turns.map { "> \($0.prompt)\n\n\($0.answerMarkdown)" }.joined(separator: "\n\n---\n\n")
    }

    // MARK: Demo

    #if DEBUG
    /// DEBUG demo commands (`DemoDirector`) run through the same state the
    /// user's input changes.
    func run(_ command: DemoDirector.Command, store: AgentChatStore) {
        // Pushed screens stop updating under the one on top, so every chat
        // screen listens and the first to see a command runs it.
        let serial = DemoDirector.shared.serial
        guard serial != lastDemoSerial else { return }
        lastDemoSerial = serial
        switch command {
        case .chatSend(let prompt):
            Task {
                // Text goes into the composer without focusing it: a raised keyboard on a
                // fresh simulator shows the system's swipe-typing tip over the composer.
                // The composer expands because it has content.
                for character in prompt {
                    text.append(character)
                    try? await Task.sleep(for: .milliseconds(28))
                }
                try? await Task.sleep(for: .milliseconds(400))
                store.send(prompt: text)
                text = ""
            }
        case .chatScroll(let toTop):
            following = !toTop
            if let scroller {
                scroller.scrollTranscript(toTop: toTop, animated: true)
            } else {
                withAnimation(.smooth(duration: 0.9)) { position.scrollTo(edge: toTop ? .top : .bottom) }
            }
        case .chatPermission(let kind):
            if let permission = store.pendingPermission,
               let option = permission.request.options.first(where: { $0.kind.rawValue == kind }) {
                withAnimation(.cmuxMobileSmooth) { store.respond(to: permission.request, option: option) }
            }
        case .chatOpenChanges, .chatOpenFirstFile:
            // The diff is awaited (cached, computing, or computed off the main thread), never run here.
            guard let turn = store.turns.last(where: \.hasEdits) else { break }
            let firstFile = command == .chatOpenFirstFile
            Task { @MainActor [weak self] in
                guard let changes = await store.diffs.changeSetReady(for: turn) else { return }
                if firstFile {
                    guard let file = changes.files.dropFirst().first ?? changes.files.first else { return }
                    self?.diffRoute = DiffRoute(changes: changes, fileID: file.id)
                } else {
                    self?.diffRoute = DiffRoute(changes: changes, fileID: nil)
                }
            }
        case .navigateBack:
            if diffRoute != nil { diffRoute = nil }
        case .chatOpenArtifacts:
            artifacts.path = []
            showArtifacts = true
        case .artifactsFilter(let name):
            if let filter = ArtifactFilter(rawValue: name) { withAnimation(.snappy) { artifacts.filter = filter } }
        case .artifactsLayout(let grid):
            artifacts.grid = grid
        case .artifactsOpen(let reference):
            let collected = SessionArtifacts.collect(turns: store.turns, subagents: store.subagents, cwd: store.summary.cwd)
            if let artifact = collected.artifacts.first(where: { $0.reference == reference }) { artifacts.path = [artifact] }
        case .artifactsSource(let on):
            artifacts.showSource = on
        case .artifactsBack:
            if !artifacts.path.isEmpty { artifacts.path.removeLast() }
        case .artifactsClose:
            showArtifacts = false
        case .chatOpenParity(let route):
            switch route {
            case "subagents": parityRoute = .subagents
            case "checkpoints": parityRoute = .checkpoints
            case "handoff": parityRoute = .handoff
            default: parityRoute = store.subagents.first(where: { $0.name == route }).map { .subagent($0.id) }
            }
        case .parityClose:
            parityRoute = nil
        case .checkpointRestore(let id):
            demoCheckpointRestore = id
        case .checkpointConfirm:
            demoConfirmRestore += 1
        case .handoffPick(let id):
            demoHandoffTarget = id
        case .handoffFill(let reference):
            demoHandoffFill = reference
        case .handoffStart:
            demoHandoffStart += 1
        default:
            break
        }
    }
    #endif
}

/// SPEC 6: the agent chat. Transcript with follow mode and jump-to-bottom,
/// composer (or the permission action bar), toolbar title menu and actions.
public struct AgentChatScreen: View {
    let store: AgentChatStore
    @State private var surface = AgentChatSurface()

    public init(store: AgentChatStore) {
        self.store = store
    }

    public var body: some View {
        // The transcript hosts the composer itself, docked to the keyboard
        // (ChatTranscriptController), instead of a SwiftUI safe-area inset.
        AgentChatTranscript(store: store, surface: surface, placement: .owned)
            .background(Color.cmuxMobileBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {

                Button("Files and Artifacts", systemImage: "folder") { surface.showArtifacts = true }
                Button("Agent Edits", systemImage: "plus.forwardslash.minus") { surface.openAllChanges(of: store) }
                    .disabled(!AgentChatSurface.hasAgentEdits(store))
                AgentParityMenuItems(store: store, surface: surface)
                Button("Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.summary.id }
                Button("Find in Chat…", systemImage: "magnifyingglass") { surface.openFind() }
                    .disabled(store.turns.isEmpty)
                if !store.modes.isEmpty {
                    Section("Mode") {
                        Picker("Mode", selection: Binding(get: { store.currentModeID ?? "" }, set: { store.setMode($0) })) {
                            ForEach(store.modes) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Text(store.displayTitle).font(.headline).lineLimit(1).truncationMode(.tail)
                        .contentTransition(.opacity)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text("\(store.summary.agentName) · \(store.summary.workspaceTitle)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: 240)
            }
            .menuOrder(.fixed)
            .accessibilityLabel(Text("\(store.displayTitle), \(store.summary.agentName) in \(store.summary.workspaceTitle)"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("Files and Artifacts", systemImage: "folder") { surface.showArtifacts = true }
                // Built when chosen: a ShareLink took the whole transcript on every streamed token.
                Button("Share Transcript", systemImage: "square.and.arrow.up") { ChatShare.present(AgentChatSurface.transcriptText(store)) }
                Button("Stop Agent", systemImage: "stop.circle", role: .destructive) { store.cancel() }
                    .disabled(!store.isRunning)
            } label: {
                // A Label, not a sized Image: the bar hosts a native button whose touch area
                // covers the whole 44 pt glass circle (a custom label view was cut to 36 pt).
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private var statusColor: Color {
        switch store.summary.status {
        case .running: .cmuxMobileWarning
        case .waiting: .cmuxMobileWarning
        case .disconnected, .closed: Color(uiColor: .tertiaryLabel)
        default: .cmuxMobileSuccess
        }
    }
}

/// The transcript of an agent chat (follow mode, jump detection, diff
/// pushes, demo commands). Pushed: under the system toolbar with the bottom
/// stack in its safe area inset. In a workspace tab: full screen under the
/// tab toolbar, with `topInset` / `bottomInset` for the chrome.
public struct AgentChatTranscript: View {
    let store: AgentChatStore
    @Bindable var surface: AgentChatSurface
    var topInset: CGFloat?
    var placement: ChatDockPlacement
    var onUserScroll: ((CGFloat) -> Void)?
    @State private var warningTrigger = 0
    /// A file the agent named (a link in an answer, a tool call's path, a diff's
    /// file), previewed full screen from the Mac.
    @State private var filePreview: FilePreviewRequest?
    #if DEBUG
    private let director = DemoDirector.shared
    #endif

    /// A workspace tab's transcript: full screen under the tab chrome, with
    /// `topInset` for the status bar. The tab's accessory draws the bottom
    /// stack; the transcript places itself above it from the keyboard
    /// layout guide and the stack's reported size. `bottomInset` is unused
    /// (kept for source compatibility). `onUserScroll` receives finger travel
    /// while the user drags (positive = finger down).
    public init(store: AgentChatStore, surface: AgentChatSurface, topInset: CGFloat? = nil, bottomInset: CGFloat? = nil,
                onUserScroll: ((CGFloat) -> Void)? = nil) {
        self.init(store: store, surface: surface, placement: .external, topInset: topInset, onUserScroll: onUserScroll)
    }

    init(store: AgentChatStore, surface: AgentChatSurface, placement: ChatDockPlacement, topInset: CGFloat? = nil,
         onUserScroll: ((CGFloat) -> Void)? = nil) {
        self.store = store
        self.surface = surface
        self.placement = placement
        self.topInset = topInset
        self.onUserScroll = onUserScroll
    }

    public var body: some View {
        let surface = surface
        let openFile = openFile
        ChatTranscriptRepresentable(
            placement: placement, surface: surface, topInset: topInset, onUserScroll: onUserScroll,
            isEmpty: !store.hasTurns,
            store: store,
            configureRows: { context in
                context.openDiff = OpenDiffAction { changes, file in surface.diffRoute = AgentChatSurface.DiffRoute(changes: changes, fileID: file) }
                context.openFile = openFile
                context.attachmentLoader = AttachmentLoader { [weak source = store.source] attachment in
                    await source?.attachmentData(attachment)
                }
                // A file link in an answer opens its preview, a cmux link what it names; web links open as before.
                context.openURL = OpenURLAction { url in
                    if CmuxLinkOpener.shared.open(url) { return .handled }
                    guard let link = FileLink(url: url) else { return .systemAction }
                    openFile(link.reference, line: link.line)
                    return .handled
                }
            },
            empty: AnyView(AgentChatEmptyState(store: store)),
            dock: placement == .owned ? AnyView(AgentChatBottomStack(store: store, surface: surface, bottomPadding: 0)) : nil,
            // Both placements: the controller hosts the circle at a fixed
            // size, 4 pt above the stack's top (verify/jump-button.md).
            jump: AnyView(AgentChatJumpButton(store: store, surface: surface))
        )
        // UIKit owns the safe areas and the keyboard (the controller docks
        // the stack to the keyboard layout guide).
        .ignoresSafeArea()
        // Find in Chat's bar, under the header (a tab's status bar inset, or the pushed bar).
        .overlay(alignment: .top) {
            if let find = surface.find {
                AgentChatFindBar(find: find, surface: surface, store: store)
                    .padding(.top, (topInset ?? 0) + 4)
                    .transition(.opacity)
            }
        }
        // UIKit owns the native top edge and the workspace's iOS 26 gradient fallback.
        .navigationDestination(item: $surface.diffRoute) { route in
            Group {
                if let file = route.fileID {
                    DiffFileScreen(changeSet: route.changes, fileID: file)
                } else {
                    DiffChangesScreen(changeSet: route.changes)
                }
            }
            .environment(\.openSessionFile, openFile)
        }
        .filePreview($filePreview)
        .navigationDestination(item: $surface.parityRoute) { route in
            AgentParityDestination(route: route, store: store, surface: surface)
        }
        .sheet(isPresented: $surface.showArtifacts) {
            SessionArtifactsSheet(store: store, surface: surface)
        }
        .sheet(isPresented: $surface.showStatus) {
            SessionStatusSheet(store: store)
        }
        .sheet(item: $surface.editingEarlier) { edit in
            if let actions = surface.tabActions {
                EarlierPromptEditSheet(edit: edit, actions: actions)
            }
        }
        .cmuxMobileSensoryFeedback(.warning, trigger: warningTrigger)
        // A live ask buzzes, and so does one a reattach caught up on (raised while the link
        // was down); one that was already waiting when the chat opened does not.
        .onChange(of: store.pendingPermission?.request.id) { _, new in
            if new != nil, let record = store.pendingPermission, !store.wasOpenOnArrival(TurnRow.permission(record).id) { warningTrigger += 1 }
        }
        .onChange(of: store.pendingQuestion?.id) { _, new in
            if let new, !store.wasOpenOnArrival(TurnRow.question(new).id) { warningTrigger += 1 }
        }
        #if DEBUG
        .onChange(of: director.serial) {
            if let command = director.command { surface.run(command, store: store) }
        }
        #endif
    }
}

extension AgentChatTranscript {
    /// Reads the file from the Mac over the link (`artifactSource`: the `file`
    /// service, confined to the folders the Mac shares; relative paths resolve
    /// against the session's folder).
    var openFile: OpenFileAction {
        let source = store.source.artifactSource
        return OpenFileAction { path, line in
            filePreview = FilePreviewRequest(reference: path, source: source, line: line)
        }
    }
}

/// Centered in the space between the header and the composer.
struct AgentChatEmptyState: View {
    let store: AgentChatStore

    var body: some View {
        if !store.hasTurns {
            VStack(spacing: 12) {
                // The agent's own mark (the Claude or Codex logo), not a generic glyph.
                AgentBrandMark(agent: store.summary.harness, size: 24, style: .brand)
                    .frame(width: 48, height: 48)
                    .background(Color.cmuxMobileSurfaceRaised, in: .circle)
                Text("What should \(store.summary.agentName) do?").font(.title3.weight(.semibold))
                Text("\(store.summary.workspaceTitle) on \(store.summary.macName)").font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The jump-to-bottom circle (SPEC 6.5).
struct AgentChatJumpButton: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    private let metrics = CmuxMobileTheme.standard.metrics

    var body: some View {
        ZStack {
            if surface.showJump {
                Button {
                    surface.scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: metrics.smallCircle, height: metrics.smallCircle)
                        .background(Color.cmuxMobileBackground.opacity(0.72), in: .circle)
                        // A tinted glass disc, so transcript text under it never reads through the arrow.
                        .glassEffect(.regular.tint(Color.cmuxMobileBackground.opacity(0.35)).interactive(), in: .circle)
                        // The 36 pt disc in a 44 pt target.
                        .frame(width: metrics.glassButton, height: metrics.glassButton)
                        .overlay(alignment: .topTrailing) {
                            if store.isRunning {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.primary)
                                    .frame(width: metrics.workingIndicatorBadge, height: metrics.workingIndicatorBadge)
                                    .background(Color.cmuxMobileBackground, in: .circle)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .accessibilityLabel("Jump to bottom")
            }
        }
        // The host's fixed size (`ChatTranscriptController.jumpHostSize`):
        // the circle appears in place, centered, from its first frame.
        .frame(width: metrics.glassButton, height: metrics.glassButton)
    }
}

/// The composer, or the permission action bar in its place (SPEC 6.9). The
/// jump-to-bottom circle (SPEC 6.5) is the transcript's
/// (`ChatTranscriptController`), so it never changes this stack's height.
public struct AgentChatBottomStack: View {
    let store: AgentChatStore
    @Bindable var surface: AgentChatSurface
    var bottomPadding: CGFloat = 8
    @State private var reportedHeight: CGFloat = 0
    /// The composer's top in the stack: what the stack shows over it (an error, plan
    /// progress, queued prompts) and their spacing.
    @State private var composerOffset: CGFloat = 0
    nonisolated private static let stackSpace = "AgentChatBottomStack"
    /// The composer field's focus (a UITextView that follows it both ways).
    @State private var composerFocused = false
    @State private var retryCount = 0

    public init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
    }

    init(store: AgentChatStore, surface: AgentChatSurface, bottomPadding: CGFloat) {
        self.store = store
        self.surface = surface
        self.bottomPadding = bottomPadding
    }

    public var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                if let error = store.clientError {
                    if store.canRetryPrompt {
                        HStack(spacing: 8) {
                            Button {
                                withAnimation(.cmuxMobileSmooth) { store.clientError = nil }
                            } label: {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Dismiss")
                            Button("Retry", systemImage: "arrow.clockwise") {
                                retryCount += 1
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.plain)
                            .disabled(surface.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && surface.attachments.isEmpty)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    } else {
                        Button {
                            withAnimation(.cmuxMobileSmooth) { store.clientError = nil }
                        } label: {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .accessibilityHint("Dismiss")
                    }
                }
                // Pinned plan progress while a turn runs (ACP web UI parity).
                if let progress = store.runningPlan, let entries = store.runningPlanEntries {
                    PlanProgressBar(progress: progress, entries: entries)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !store.queue.isEmpty {
                    QueuedPromptsView(store: store, text: $surface.text)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let permission = store.pendingPermission, !surface.permissionBarHidden {
                    PermissionActionBar(request: permission.request, approvingOptionID: store.approvingOptionID) { option in
                        withAnimation(.cmuxMobileSmooth) { store.respond(to: permission.request, option: option) }
                    } replyInstead: {
                        withAnimation(.cmuxMobileSmooth) { surface.replyInsteadOfPermission = true }

                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
                    .padding(.horizontal, 12)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
                } else {
                    let replying = store.pendingPermission != nil && surface.replyInsteadOfPermission
                    ChatComposer(store: store, text: $surface.text, attachments: $surface.attachments, focus: $composerFocused, collapsible: store.hasTurns,
                                 expandOnAppear: surface.replyInsteadOfPermission,
                                 placeholderOverride: replying ? "Tell \(store.summary.agentName) what to do instead" : nil,
                                 denyingPermission: replying,
                                 suggestionsCeiling: surface.stackCeiling.map { $0 + composerOffset },
                                 retryCount: retryCount,
                                 cmuxCommands: CmuxSlashCommand.allCases.filter { $0 != .fork || surface.tabActions != nil },
                                 runCmuxCommand: { [surface, store] command, args in
                                     await surface.run(command, args: args, store: store)
                                 })
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.stackSpace)).minY }) { offset in
                            if composerOffset != offset { composerOffset = offset }
                        }
                        .transition(.opacity)
                }
            }
            .coordinateSpace(.named(Self.stackSpace))
            // The transcript's bottom margin follows this top. The jump
            // button is not in this stack: counting it moved the margin,
            // which moved the distance, which toggled the button (a layout
            // loop that flickered and could hang after a tab zoom).
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                surface.bottomStackTop = frame.minY
                if surface.stackHeight != frame.height { surface.stackHeight = frame.height }
                if surface.stackMaxY != frame.maxY { surface.stackMaxY = frame.maxY }
                if reportedHeight != frame.height {
                    // Interpolated on the composer's spring (`.cmuxMobileSmooth`):
                    // the reporter below hands the transcript every frame.
                    if reportedHeight == 0 || store.placeBottomStackInstantly {
                        store.placeBottomStackInstantly = false
                        reportedHeight = frame.height
                    } else {
                        withAnimation(.cmuxMobileSmooth) { reportedHeight = frame.height }
                    }
                }
            }
            .modifier(DrawnHeightReporter(height: reportedHeight) { height in
                surface.drawnStackHeight = height
                surface.stackHeightFrame?(height)
            })
            // As in Messages, a downward swipe on the composer takes the
            // keyboard down (the transcript's interactive dismissal covers
            // drags that start above it).
            .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { value in
                let t = value.translation
                if composerFocused, t.height > 14, t.height > abs(t.width) * 1.5 { composerFocused = false }
            })
        }
        .padding(.bottom, bottomPadding)
        // History (the chat opening, a reattach) brings its open ask and queue in place.
        .animation(store.lastChangeWasReplay ? nil : .cmuxMobileSmooth, value: store.pendingPermission?.request.id)
        .animation(store.lastChangeWasReplay ? nil : .cmuxMobileSmooth, value: store.queue)
        .onChange(of: store.pendingPermission?.request.id) { _, new in
            surface.replyInsteadOfPermission = false
            // Never pull the composer out from under someone typing.
            let drafting = composerFocused || !surface.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !surface.attachments.isEmpty
            surface.permissionDeferred = new != nil && drafting
        }
        .onChange(of: surface.composerFocused) { _, focused in if composerFocused != focused { composerFocused = focused } }
        .task {
            // Opened focused (a new chat): the field exists once this appears.
            if surface.composerFocused, !composerFocused { composerFocused = true }
        }
        .onChange(of: composerFocused) { _, focused in
            if surface.composerFocused != focused { surface.composerFocused = focused }
            // Leaving "Reply instead" without typing brings the permission choices back.
            if !focused, surface.permissionBarHidden, surface.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, surface.attachments.isEmpty {
                withAnimation(.cmuxMobileSmooth) { surface.showPermissionChoices() }
            }
        }
    }
}

/// Hands its animated height to `report` on every frame it is drawn (an
/// animatable modifier's body runs once per animation frame with the
/// interpolated value).
nonisolated struct DrawnHeightReporter: ViewModifier, Animatable {
    var height: CGFloat
    let report: @MainActor (CGFloat) -> Void

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            // SwiftUI sets the interpolated value here once per frame, on
            // the main thread, or on its asynchronous render thread (seen
            // during an interactive keyboard dismissal on iOS 27), which
            // hands the value to the main thread.
            guard newValue > 0 else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { report(newValue) }
            } else {
                let report = report
                DispatchQueue.main.async { report(newValue) }
            }
        }
    }

    @MainActor func body(content: Content) -> some View {
        content.onAppear { if height > 0 { report(height) } }
    }
}

/// Title-menu entries for the parity screens (pushed chat and workspace tab).
public struct AgentParityMenuItems: View {
    let store: AgentChatStore
    let surface: AgentChatSurface

    public init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
    }

    public var body: some View {
        Section {
            Button(store.subagents.isEmpty ? "Subagents" : "Subagents (\(store.subagents.count))", systemImage: "person.2.wave.2") {
                surface.parityRoute = .subagents
            }
            // Only where the session can list and restore them: the phone
            // link does not carry checkpoints yet.
            if store.source.supportsCheckpoints {
                Button("Checkpoints", systemImage: "clock.arrow.circlepath") { surface.parityRoute = .checkpoints }
            }
            Button("Continue in…", systemImage: "arrow.triangle.branch") { surface.parityRoute = .handoff }
        }
    }
}

/// Committed blocks render once; only the tail block re-renders each tick (SPEC 6.3).
struct StreamingMarkdown: View {
    let markdown: String
    let isStreaming: Bool
    var animatesBlocks = true
    /// Find in Chat's marks on this message's blocks.
    var findMarks: (any MarkdownBlockMarks)?

    /// The parse, kept across bodies: a streamed token re-parses the message's tail only.
    @State private var parse = StreamParseBox()

    var body: some View {
        // While streaming, an emphasis or code marker that has not closed yet is hidden (the
        // blocks keep their ids: only the last block's inline markers change).
        MarkdownView(MarkdownDocument(blocks: parse.blocks(markdown, isStreaming: isStreaming)), isStreaming: isStreaming,
                     animatesBlocks: animatesBlocks, marks: findMarks)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = markdown }
                ShareLink(item: markdown) { Label("Share", systemImage: "square.and.arrow.up") }
            }
    }
}

/// Holds a message's incremental parse for a view (not observed: it changes only with its input).
final class StreamParseBox {
    private var parse = MarkdownStreamParse()

    func blocks(_ markdown: String, isStreaming: Bool) -> [MarkdownBlock] {
        parse.update(markdown, isStreaming: isStreaming)
        return parse.displayed
    }
}

/// SPEC 4.4 user bubble with a timestamp-headed context menu and select-text sheet.
struct UserBubble: View {
    let prompt: String
    let attachments: [AgentAttachment]
    let promptAt: Date
    let isLast: Bool
    let editAndResend: () -> Void
    /// Edit and Resend of an earlier prompt (a fork before it), when the chat offers it.
    var editEarlier: (() -> Void)?
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            Text(prompt)
                .font(.body)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.cmuxMobileBubble, in: .rect(cornerRadius: 20, style: .continuous))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Section(AgentTurn.menuTimestamp(promptAt)) {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = prompt }
                        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = true }
                        if isLast {
                            Button("Edit and Resend", systemImage: "pencil") { editAndResend() }
                        } else if let editEarlier {
                            Button("Edit and Resend", systemImage: "pencil") { editEarlier() }
                        }
                        ShareLink(item: prompt) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sheet(isPresented: $selecting) {
            NavigationStack {
                ScrollView {
                    Text(prompt).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { selecting = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Sent attachments above the user bubble (SPEC 4.4 "images above text as
/// a stacked strip, radius 16"): a lone image shows large like ChatGPT and
/// Messages; several share a row of squares; files stay chips. Trailing
/// edges line up with the bubble (no remove-badge room).
struct SentAttachments: View {
    let attachments: [AgentAttachment]
    /// A tapped attachment: every attachment of the message opens full screen, to swipe between.
    @State private var preview: FilePreviewRequest?
    /// Bytes read for recorded images (a prompt this launch did not send).
    @State private var fetched: [String: Data] = [:]
    /// Thumbnails decoded off the main thread, by attachment id (never decoded in a body).
    @State private var decoded: [String: UIImage] = [:]
    private let thumbnails = SentAttachmentThumbnails.shared
    @Environment(\.attachmentLoader) private var loader

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
        VStack(alignment: .trailing, spacing: 6) {
            if images.count == 1, let image = images.first {
                thumbnail(image, size: SentAttachmentThumbnails.size(images: 1))
            } else if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images.prefix(3)) { image in
                        thumbnail(image, size: SentAttachmentThumbnails.size(images: images.count))
                            .overlay {
                                if image.id == images.prefix(3).last?.id, images.count > 3 {
                                    Text("+\(images.count - 3)").font(.headline).foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 16, style: .continuous))
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            ForEach(files) { file in
                AttachmentThumb(attachment: file, open: { open(file) }).padding(.top, -6).padding(.trailing, -6)
            }
        }
        .filePreview($preview)
    }

    /// Images first, then files: the order they show in. A recorded image's bytes come from the
    /// session (read once here, or by the preview when it opens first).
    private func open(_ attachment: AgentAttachment) {
        let ordered = attachments.filter { $0.kind == .image } + attachments.filter { $0.kind != .image }
        let files = ordered.map { item in
            var file = item.localFile
            if file.data == nil { file.data = fetched[item.id] }
            return file
        }
        let load = loader.load
        preview = FilePreviewRequest(files: files, startingAt: attachment.id) { file in
            await load(AgentAttachment(id: file.id, kind: file.isImage ? .image : .file, name: file.name))
        }
    }

    @ViewBuilder
    private func thumbnail(_ attachment: AgentAttachment, size: CGSize) -> some View {
        let side = SentAttachmentThumbnails.side(size)
        Group {
            // Decoded by this view's `.task`, or already (a tab card's picture runs no `.task`:
            // its key waits for the thumbnail, `SentAttachmentThumbnails.ready`).
            if let image = decoded[attachment.id]
                ?? (attachment.data ?? fetched[attachment.id]).flatMap({ thumbnails.image(attachment, data: $0, side: side) }) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.cmuxMobileFill.overlay { Image(systemName: "photo").font(.title3).foregroundStyle(.secondary) }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
        // Tap opens it full screen (swipe to the message's other attachments).
        .onTapGesture { open(attachment) }
        .task(id: attachment.id) {
            var data = attachment.data ?? fetched[attachment.id]
            if data == nil, let loaded = await loader.load(attachment) {
                fetched[attachment.id] = loaded
                data = loaded
            }
            guard let data, decoded[attachment.id] == nil else { return }
            if let image = await thumbnails.decode(attachment, data: data, side: side) { decoded[attachment.id] = image }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Image, \(attachment.name)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens full screen")
    }
}

extension SentAttachments {
    /// The image's size scaled so its short side is `side` (a fill thumbnail).
    nonisolated static func fill(_ size: CGSize, side: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: side, height: side) }
        let scale = min(1, side / min(size.width, size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Reads the bytes of an attachment a recorded prompt names (`AgentSessionSource.attachmentData`).
struct AttachmentLoader: Sendable {
    let load: @MainActor @Sendable (AgentAttachment) async -> Data?
}

extension EnvironmentValues {
    @Entry var attachmentLoader = AttachmentLoader { _ in nil }
}

/// Retry with another model (the Mac's turn menu, cx-ncc.62): the chat harness's models, the
/// one it runs checked. Shown with two or more models; a pick moves the chat and sends the
/// prompt again, and a model the Mac refuses (a Claude chat the Mac started) says why in the
/// chat with the Mac's words, sending nothing.
@MainActor
struct RetryModelChoice {
    let store: AgentChatStore
    let turn: AgentTurn

    init?(store: AgentChatStore, turn: AgentTurn) {
        guard !store.retryModels.isEmpty else { return nil }
        self.store = store
        self.turn = turn
    }

    /// The Mac's title (`turn.retryWith`).
    static let title = "Retry with another model"

    var menu: some View {
        Menu {
            ForEach(store.retryModels) { model in
                Button {
                    store.retry(turn, model: model.id)
                } label: {
                    if model.id == store.currentModelID {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            Label(Self.title, systemImage: "arrow.triangle.2.circlepath")
        }
        .accessibilityIdentifier("chat.retryWithModel")
    }
}

/// SPEC 4.4 action row: copy, share, retry, more; trailing duration.
struct AnswerActionRow: View {
    let turn: AgentTurn
    let isLast: Bool
    /// The 44 pt targets reach into the stack's spacing (a turn's stack); a transcript
    /// cell places the row with that gap itself.
    var insetsTargets = true
    var retryWith: RetryModelChoice?
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            IconAction(copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                UIPasteboard.general.string = turn.answerMarkdown
                withAnimation(.cmuxMobileSnap) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.cmuxMobileSnap) { copied = false }
                }
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: copied) { _, new in
                new && CmuxMobileTheme.standard.haptics.isEnabled
            }
            ShareLink(item: turn.answerMarkdown) {
                IconActionLabel("square.and.arrow.up")
            }
            .accessibilityLabel("Share")
            if isLast {
                IconAction("arrow.clockwise", label: "Retry", action: retry)
            }
            Menu {
                Section(AgentTurn.menuTimestamp(turn.endedAt ?? turn.promptAt)) {
                    Button("Copy as Markdown", systemImage: "text.document") { UIPasteboard.general.string = turn.answerMarkdown }
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    retryWith?.menu
                }
            } label: {
                IconActionLabel("ellipsis")
            }
            .accessibilityLabel("More")
            Spacer()
            if let duration = turn.duration {
                Text(ToolWording().duration(duration)).font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
            }
        }
        // At accessibility sizes the glyphs stop growing at AX1 (90 pt targets made the
        // row wider than the column).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // 44 pt targets on a 32 pt visual row: the extra height overlaps the row's margins.
        .padding(.vertical, insetsTargets ? -6 : 0)
        .padding(.top, insetsTargets ? 2 : 0)
        .padding(.leading, -14)
    }
}

#if DEBUG
/// `-cmux-mobile-row-heights`: logs every size a transcript row is asked for and where it is
/// placed, to `Documents/row-heights.txt` (round 3: measured vs drawn heights at AX5).
struct RowHeightProbe: Layout {
    let name: String
    static let isEnabled = CommandLine.arguments.contains("-cmux-mobile-row-heights")
    nonisolated(unsafe) static var handle: FileHandle? = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("row-heights.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    static func log(_ line: String) { handle?.write(Data((line + "\n").utf8)) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        Self.log("fit \(name) w=\(proposal.width.map { "\($0)" } ?? "nil") h=\(proposal.height.map { "\($0)" } ?? "nil") -> \(size.width)x\(size.height)")
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        Self.log("place \(name) \(bounds.width)x\(bounds.height) at y=\(bounds.minY)")
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
#endif

extension View {
    @ViewBuilder
    func rowHeightProbe(_ name: String) -> some View {
        #if DEBUG
        if RowHeightProbe.isEnabled {
            RowHeightProbe(name: name) { self }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
#endif
