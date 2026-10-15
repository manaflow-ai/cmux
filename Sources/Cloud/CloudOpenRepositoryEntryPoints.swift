import AppKit
import CmuxCloud
import CmuxCommandPalette
import CmuxFoundation
import SwiftUI
import UniformTypeIdentifiers

// Every way into "Open Repository in Cloud…". Each one only gathers a prefill and
// calls ``CloudOpenRepositoryPresenter``; none runs a clone itself.

// MARK: - App action and `cmux://cloud/clone`

extension AppDelegate {
    /// Opens the sheet: the one action behind the Cloud menu, the palette and the panel.
    @MainActor
    func performOpenRepositoryInCloudAction(
        repository: String? = nil,
        agent: CloudOpenRepositoryCommand.Agent? = nil,
        prompt: String? = nil,
        preferredWindow: NSWindow?,
        debugSource: String
    ) {
#if DEBUG
        cmuxDebugLog("cloudOpenRepository.present source=\(debugSource) prefilled=\(repository != nil)")
#endif
        guard CloudMachinesFeature.isEnabled else {
            NSSound.beep()
            return
        }
        CloudOpenRepositoryPresenter.shared.present(
            repository: repository,
            agent: agent,
            prompt: prompt,
            preferredWindow: preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    /// Claims `<scheme>://cloud/clone` links. The sheet opens prefilled and waits for
    /// the person; a link never starts a clone.
    @MainActor
    func handleCloudOpenRepositoryURLs(from urls: [URL]) -> Bool {
        let requests = urls.compactMap { CloudOpenRepositoryURLRequest.parse($0) }
        guard let request = requests.first else { return false }
        if requests.count > 1 {
            // Several links at once is not a decision a sheet can present; open none.
            NSSound.beep()
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        performOpenRepositoryInCloudAction(
            repository: request.repository,
            agent: request.agent,
            prompt: request.prompt,
            preferredWindow: nil,
            debugSource: "url.cloudClone"
        )
        return true
    }
}

// MARK: - Command palette

extension ContentView {
    static let commandPaletteCloudOpenRepositoryCommandId = "palette.cloud.openRepository"

    static func commandPaletteCloudOpenRepositoryContributions(
        isAuthenticated: Bool? = nil
    ) -> [CommandPaletteCommandContribution] {
        guard CloudMachinesFeature.isEnabled,
              isAuthenticated ?? (AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true) else { return [] }
        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudOpenRepositoryCommandId,
                title: { _ in String(localized: "cloudOpenRepository.menu", defaultValue: "Open Repository in Cloud…") },
                subtitle: { _ in String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud") },
                keywords: ["cloud", "repository", "repo", "clone", "github", "git", "url", "open", "checkout"]
            ),
        ]
    }

    func registerCloudOpenRepositoryCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        let commandWindow = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        registry.register(commandId: Self.commandPaletteCloudOpenRepositoryCommandId) {
            AppDelegate.shared?.performOpenRepositoryInCloudAction(
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.openRepository"
            )
        }
    }
}

// MARK: - Cloud panel: paste

extension CloudTreeNSOutlineView {
    /// ⌘V on the Cloud tree with a GitHub link on the clipboard opens the sheet for it.
    /// Anything else continues up the responder chain unchanged.
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string),
           CloudOpenRepositoryPresenter.shared.presentIfGitHubRepository(text: text, preferredWindow: window) {
            return
        }
        if nextResponder?.tryToPerform(#selector(paste(_:)), with: sender) != true {
            NSSound.beep()
        }
    }
}

// MARK: - Cloud panel: button and drop target

/// The Cloud panel's quiet "Open Repository…" row under New Cloud Machine.
struct CloudOpenRepositoryPanelButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let title = String(localized: "cloudOpenRepository.panel.button", defaultValue: "Open Repository…")
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .cmuxFont(size: 12)
                    .lineLimit(1)
            }
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? CloudTreeHoverStyle.hoverOpacity : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut), value: isHovered)
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.bottom, 2)
        .help(String(
            localized: "cloudOpenRepository.panel.help",
            defaultValue: "Clone a repository on a Cloud machine. You can also paste or drop a GitHub link on this panel."
        ))
        .accessibilityLabel(title)
        .accessibilityIdentifier("CloudOpenRepositoryPanelButton")
    }
}

extension View {
    /// Accepts a GitHub link dropped on the Cloud panel and opens the sheet for it.
    /// Tree rows and tabs keep their own drags: a drag that carries them is refused.
    func cloudOpenRepositoryDropTarget() -> some View {
        modifier(CloudOpenRepositoryDropTarget())
    }
}

private struct CloudOpenRepositoryDropTarget: ViewModifier {
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.url, .plainText], delegate: CloudOpenRepositoryDropDelegate(isTargeted: $isTargeted))
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .overlay {
                            Text(String(
                                localized: "cloudOpenRepository.drop.title",
                                defaultValue: "Drop a GitHub link to open it in Cloud"
                            ))
                            .cmuxFont(size: 12, weight: .medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("CloudOpenRepositoryDropTarget")
                }
            }
    }
}

private struct CloudOpenRepositoryDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    /// Drags the panel already owns (tree rows, workspace tabs) are never a repository.
    static let ownedTypes: [UTType] = [
        UTType(importedAs: NSPasteboard.PasteboardType.cloudSidebarRow.rawValue),
        UTType(importedAs: DragOverlayRoutingPolicy.bonsplitTabTransferType.rawValue),
    ]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.url, .plainText]) && !info.hasItemsConforming(to: Self.ownedTypes)
    }

    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        if let provider = info.itemProviders(for: [.url]).first {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let text = url?.absoluteString
                Task { @MainActor in Self.present(text) }
            }
            return true
        }
        if let provider = info.itemProviders(for: [.plainText]).first {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                let text = (string as? NSString).map { String($0) }
                Task { @MainActor in Self.present(text) }
            }
            return true
        }
        return false
    }

    @MainActor
    private static func present(_ text: String?) {
        // The panel lives in the key window; the presenter attaches the sheet there.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let text, CloudOpenRepositoryPresenter.shared.presentIfGitHubRepository(text: text, preferredWindow: window) else {
            NSSound.beep()
            return
        }
    }
}
