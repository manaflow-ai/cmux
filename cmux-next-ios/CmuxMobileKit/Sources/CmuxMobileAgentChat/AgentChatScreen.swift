#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileArtifacts
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
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
    /// Find in Chat while its bar is up (nil: closed).
    public var find: AgentChatFind?
    /// Each searchable block's frame (top, height) in the transcript's content coordinates
    /// (Find in Chat scrolls to its current match). Written as rows lay out; never observed.
    @ObservationIgnored var findAnchors: [String: (top: CGFloat, height: CGFloat)] = [:]
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

    /// Scrolls the transcript to the find bar's current match.
    func revealFindMatch() {
        guard let match = find?.currentMatch, let frame = findAnchors[match.block] else { return }
        // The match's line in a long answer: its place in the text, as a share of the block.
        let y = frame.top + max(0, frame.height * CGFloat(match.position) - 24)
        scroller?.scrollTranscript(toContentY: y, animated: !UIAccessibility.isReduceMotionEnabled)
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
    /// Screen y of the top of the floating bottom stack (tab mode), so the
    /// transcript's bottom margin follows the composer and the keyboard.
    public internal(set) var bottomStackTop: CGFloat?
    /// The bottom stack's height and bottom edge in screen space, so a
    /// transcript whose stack is drawn elsewhere (a workspace tab) can place
    /// it from the keyboard layout guide in the keyboard's own animation.
    public internal(set) var stackHeight: CGFloat?
    public internal(set) var stackMaxY: CGFloat?
    /// The live transcript's scroll view (jump to bottom, demos).
    @ObservationIgnored weak var scroller: (any ChatTranscriptScrolling)?
    /// The bottom stack's height as drawn, once per frame while it animates
    /// (the transcript's inset follows it in the same frame).
    @ObservationIgnored var stackHeightFrame: ((CGFloat) -> Void)?
    @ObservationIgnored var drawnStackHeight: CGFloat?

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
        store.turns.contains { !$0.edits.isEmpty }
    }

    public func scrollToBottom(animated: Bool = true) {
        following = true
        if let scroller {
            scroller.scrollTranscript(toTop: false, animated: animated)
        } else if animated {
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
        case .chatOpenChanges:
            if let changes = store.turns.last(where: { $0.changeSet != nil })?.changeSet {
                diffRoute = DiffRoute(changes: changes, fileID: nil)
            }
        case .chatOpenFirstFile:
            if let changes = store.turns.last(where: { $0.changeSet != nil })?.changeSet, let file = changes.files.dropFirst().first ?? changes.files.first {
                diffRoute = DiffRoute(changes: changes, fileID: file.id)
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
            .toolbar(.hidden, for: .tabBar)
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
                ShareLink(item: AgentChatSurface.transcriptText(store)) { Label("Share Transcript", systemImage: "square.and.arrow.up") }
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
        ChatTranscriptRepresentable(
            placement: placement, surface: surface, topInset: topInset, onUserScroll: onUserScroll,
            isEmpty: store.turns.isEmpty,
            identity: ObjectIdentifier(store),
            content: AnyView(AgentChatTurns(store: store, surface: surface)
                .environment(\.openDiff, OpenDiffAction { changes, file in surface.diffRoute = AgentChatSurface.DiffRoute(changes: changes, fileID: file) })
                .environment(\.openSessionFile, openFile)
                .environment(\.attachmentLoader, AttachmentLoader { [weak source = store.source] attachment in
                    await source?.attachmentData(attachment)
                })
                // A file link in an answer opens its preview; web links open as before.
                .environment(\.openURL, OpenURLAction { url in
                    guard let link = FileLink(url: url) else { return .systemAction }
                    openFile(link.reference, line: link.line)
                    return .handled
                })),
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
        // The soft top edge under the status bar or bar is the controller's TopFadeView.
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
        .sensoryFeedback(.warning, trigger: warningTrigger)
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

/// The turns of an agent chat (hosted in the transcript's scroll view).
struct AgentChatTurns: View {
    let store: AgentChatStore
    let surface: AgentChatSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let first = store.turns.first {
                Text("Session started \(first.promptAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            }
            ForEach(store.turns) { turn in
                // Exactly the column's width: one row that cannot shrink never widens the turn.
                ProposedWidthLayout {
                    TurnView(turn: turn, store: store, isLast: turn.id == store.turns.last?.id, surface: surface)
                }
                    .rowHeightProbe("turn-\(turn.id)")
                    .padding(.bottom, 24)
                    .id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .coordinateSpace(.named(AgentChatFindBar.contentSpace))
    }
}

/// Centered in the space between the header and the composer.
struct AgentChatEmptyState: View {
    let store: AgentChatStore

    var body: some View {
        if store.turns.isEmpty {
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

    var body: some View {
        ZStack {
            if surface.showJump {
                Button {
                    surface.scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .overlay {
                            if store.isRunning {
                                PulsingRing()
                            }
                        }
                        .background(Color.cmuxMobileBackground.opacity(0.72), in: .circle)
                        // A tinted glass disc, so transcript text under it never reads through the arrow.
                        .glassEffect(.regular.tint(Color.cmuxMobileBackground.opacity(0.35)).interactive(), in: .circle)
                        // The 36 pt disc in a 44 pt target.
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .accessibilityLabel("Jump to bottom")
            }
        }
        // The host's fixed size (`ChatTranscriptController.jumpHostSize`):
        // the circle appears in place, centered, from its first frame.
        .frame(width: 44, height: 44)
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
    /// The composer field's focus (a UITextView that follows it both ways).
    @State private var composerFocused = false

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
                    ChatComposer(store: store, text: $surface.text, attachments: $surface.attachments, focus: $composerFocused, collapsible: !store.turns.isEmpty,
                                 expandOnAppear: surface.replyInsteadOfPermission,
                                 placeholderOverride: replying ? "Tell \(store.summary.agentName) what to do instead" : nil,
                                 denyingPermission: replying)
                        .transition(.opacity)
                }
            }
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

struct PulsingRing: View {
    @State private var on = false

    var body: some View {
        Circle()
            .strokeBorder(Color.primary, lineWidth: 2)
            .opacity(on ? 0.9 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// One turn: user bubble, the agent's rows, working label, changes card, actions.
struct TurnView: View {
    let turn: AgentTurn
    let store: AgentChatStore
    let isLast: Bool
    var surface: AgentChatSurface?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Replayed history (the transcript on open, a reattach's catch-up) is drawn in
            // place; only what arrives live animates in.
            UserBubble(turn: turn, isLast: isLast) { store.send(prompt: $0) }
                .findBlock(AgentChatFind.promptKey(turn.id), surface: surface)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.asymmetric(insertion: store.isReplayed(turn.id) ? .identity
                    : .offset(y: 24).combined(with: .scale(scale: 0.96)).combined(with: .opacity), removal: .opacity))
            VStack(alignment: .leading, spacing: 10) {
                let rows = turn.rows
                ForEach(rows) { row in
                    rowView(row, isLastRow: row.id == rows.last?.id)
                        .rowHeightProbe("\(row.id)")
                        .transition(.asymmetric(insertion: store.isReplayed(row.id) ? .identity : .opacity, removal: .opacity)
                            .animation(.easeOut(duration: 0.15)))
                }
                if turn.status == .running, rows.needsWorkingIndicator, store.pendingPermission == nil, store.pendingQuestion == nil {
                    WorkingLabel(turn.retry?.label ?? "Working", since: turn.startedAt)
                        .frame(minHeight: 28)
                        .transition(.opacity)
                }
                if turn.status != .running, let changes = turn.changeSet {
                    EditedFilesCard(changeSet: changes).padding(.top, 4)
                }
                switch turn.status {
                case .cancelled:
                    Text("Stopped").font(.footnote).foregroundStyle(.tertiary)
                case .failed:
                    let failure = TurnFailureCopy(message: turn.errorText, harness: store.summary.harness, harnessName: store.summary.agentName)
                    FailureCard(title: "Agent stopped", message: failure.sentence, detail: failure.detail) {
                        store.send(prompt: turn.prompt)
                    }
                case .completed:
                    AnswerActionRow(turn: turn, isLast: isLast) { store.send(prompt: turn.prompt) }
                case .running:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TurnRow, isLastRow: Bool) -> some View {
        switch row {
        case .message(_, let markdown):
            // A replayed message's blocks are drawn in place too, not faded in one by one
            // (one still streaming when the chat opened streams on without the block fade).
            StreamingMarkdown(markdown: markdown, isStreaming: turn.status == .running && isLastRow,
                              animatesBlocks: !store.isReplayed(row.id))
                .findBlock(row.id, surface: surface)
        case .thought(_, let text):
            ThoughtRow(text: text, isLive: turn.status == .running && isLastRow)
        case .tool(let call):
            // One row (same id) as the run grows into a group: swap in
            // place instead of crossfading two labels over each other.
            ToolRowView(call: call).transition(.identity)
        case .toolGroup(_, let calls):
            ToolGroupView(calls: calls, turnRunning: turn.status == .running).transition(.identity)
        case .edit(let call):
            if call.isRunning {
                ToolRowView(call: call)
            } else {
                DiffSnippet(call: call, changeSet: turn.changeSet ?? DiffChangeSet(id: call.id, title: "Changes", subtitle: "", files: []))
            }
        case .plan(_, let entries):
            PlanCard(entries: entries)
        case .permission(let record):
            PermissionCard(record: record, agentName: store.summary.agentName,
                           showChoices: surface?.permissionBarHidden == true && record.request.id == store.pendingPermission?.request.id
                               ? { withAnimation(.cmuxMobileSmooth) { surface?.showPermissionChoices() } } : nil)
        case .question(let id):
            if let question = turn.question(id) {
                QuestionCard(question: question) { store.answer(question, with: $0) }
                if question.isPending, question.source.rejectOption != nil {
                    // A phone's answer can be refused (only the Mac may answer); a decline always goes through.
                    Button("Decline") { store.decline(question) }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        case .subagents(_, let ids):
            SubagentGroupCard(ids: ids, store: store) { surface?.parityRoute = .subagent($0) }
        }
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

    var body: some View {
        // While streaming, an emphasis or code marker that has not closed yet is hidden.
        MarkdownView(MarkdownDocument(parsing: isStreaming ? MarkdownStreamTail(markdown).displayed : markdown), isStreaming: isStreaming,
                     animatesBlocks: animatesBlocks)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = markdown }
                ShareLink(item: markdown) { Label("Share", systemImage: "square.and.arrow.up") }
            }
    }
}

/// SPEC 4.4 user bubble with a timestamp-headed context menu and select-text sheet.
struct UserBubble: View {
    let turn: AgentTurn
    let isLast: Bool
    let resend: (String) -> Void
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !turn.attachments.isEmpty {
                SentAttachments(attachments: turn.attachments)
            }
            Text(turn.prompt)
                .font(.body)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.cmuxMobileBubble, in: .rect(cornerRadius: 20, style: .continuous))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Section(AgentTurn.menuTimestamp(turn.promptAt)) {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.prompt }
                        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = true }
                        if isLast {
                            Button("Edit and Resend", systemImage: "pencil") { resend(turn.prompt) }
                        }
                        ShareLink(item: turn.prompt) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sheet(isPresented: $selecting) {
            NavigationStack {
                ScrollView {
                    Text(turn.prompt).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
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
    @Environment(\.attachmentLoader) private var loader

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
        VStack(alignment: .trailing, spacing: 6) {
            if images.count == 1, let image = images.first {
                thumbnail(image, size: CGSize(width: 200, height: 150))
            } else if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images.prefix(3)) { image in
                        thumbnail(image, size: CGSize(width: 96, height: 96))
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
        Group {
            if let data = attachment.data ?? fetched[attachment.id], let image = UIImage(data: data) {
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
            guard attachment.data == nil, fetched[attachment.id] == nil, let data = await loader.load(attachment) else { return }
            fetched[attachment.id] = data
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Image, \(attachment.name)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens full screen")
    }
}

/// Reads the bytes of an attachment a recorded prompt names (`AgentSessionSource.attachmentData`).
struct AttachmentLoader: Sendable {
    let load: @MainActor @Sendable (AgentAttachment) async -> Data?
}

extension EnvironmentValues {
    @Entry var attachmentLoader = AttachmentLoader { _ in nil }
}

/// SPEC 4.4 action row: copy, share, retry, more; trailing duration.
struct AnswerActionRow: View {
    let turn: AgentTurn
    let isLast: Bool
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
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: copied) { _, new in new }
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
        .padding(.vertical, -6)
        .padding(.top, 2)
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
