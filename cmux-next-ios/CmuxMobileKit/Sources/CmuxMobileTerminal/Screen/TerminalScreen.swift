#if os(iOS) && DEBUG
import SwiftUI

/// DEBUG only (the terminal demo): workspace tabs host terminals through
/// `TerminalTabPage`. The terminal screen (SPEC 10): Ghostty full bleed, system glass toolbar with
/// the title menu and the keyboard toggle, the keyboard-pinned bottom stack,
/// and the files-and-links sheet. Push it inside a NavigationStack.
public struct TerminalScreen: View {
    @State private var model: TerminalModel
    private let tabs: [TerminalTabItem]

    public init(model: TerminalModel, tabs: [TerminalTabItem] = []) {
        _model = State(initialValue: model)
        self.tabs = tabs
    }

    #if DEBUG
    /// A mock terminal, for UI work without a Mac (DEBUG builds only).
    public init(mockTitle: String = "zsh", tabs: [TerminalTabItem] = []) {
        self.init(model: TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: mockTitle), tabs: tabs)
    }
    #endif

    public var body: some View {
        TerminalControllerView(model: model)
            .ignoresSafeArea()
            .background(Color.black)
            .overlay {
                if !model.connectionState.isAttached {
                    TerminalConnectingView(state: model.connectionState, retry: model.reconnect).transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { titleMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.toggleKeyboard()
                    } label: {
                        Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(model.keyboardVisible ? "Hide Keyboard" : "Show Keyboard")
                    .accessibilityIdentifier("terminal.keyboardToggle")
                    moreMenu
                }
            }
            .sheet(isPresented: $model.showArtifacts) {
                ArtifactsSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var titleMenu: some View {
        Menu {
            Section {
                ForEach(tabs) { tab in
                    Button {
                        tab.select()
                    } label: {
                        Label(tab.title, systemImage: tab.isCurrent ? "checkmark" : tab.systemImage)
                    }
                }
            }
            Section("Connection") {
                Text("Mock session · local")
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("\(model.title), tabs")
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("Files and Links", systemImage: "folder") { model.showArtifacts = true }
                Button("Paste", systemImage: "doc.on.clipboard") { model.controller?.surface.paste(nil) }
                Button("Send Ctrl-C", systemImage: "xmark.octagon") { model.keyBar(.chord("c")) }
                Button("Clear", systemImage: "clear") { model.keyBar(.chord("l")) }
            }
            Section {
                Button("Scroll to bottom", systemImage: "arrow.down.to.line") { model.scrollToBottom() }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("terminal.more")
    }
}

/// A tab in the title menu.
public struct TerminalTabItem: Identifiable {
    public let id: String
    public var title: String
    public var systemImage: String
    public var isCurrent: Bool
    public var select: () -> Void

    public init(id: String, title: String, systemImage: String, isCurrent: Bool, select: @escaping () -> Void = {}) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isCurrent = isCurrent
        self.select = select
    }
}

struct TerminalControllerView: UIViewControllerRepresentable {
    let model: TerminalModel

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(model: model)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {}
}
#endif
