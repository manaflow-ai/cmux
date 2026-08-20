#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShellModel
import Foundation
import SwiftUI

/// DEBUG-only fixture host for the Mac-surface renderers.
///
/// Mounted by the root view when `CMUX_UITEST_MAC_SURFACE_GALLERY` names a
/// page (`todo`, `file`, `markdown`, `fallback`, or `picker`). It renders the
/// production surface components with stubbed data and loaders so dark/light
/// simulator screenshots don't require sign-in, pairing, or a live Mac.
/// Unlike the production host — which locks the overlay's `colorScheme` to
/// the Mac terminal theme — the gallery follows the device appearance so
/// `simctl ui appearance` exercises both palettes of the same views.
public struct MacSurfaceGalleryPreviewView: View {
    private let page: String

    /// Creates the gallery for the page named in the launch environment.
    public init() {
        page = ProcessInfo.processInfo.environment["CMUX_UITEST_MAC_SURFACE_GALLERY"] ?? "todo"
    }

    public var body: some View {
        switch page {
        case "file":
            PanelFileSurfaceView(
                surface: Self.fileSurface,
                path: Self.textPath,
                loader: Self.fixtureLoader,
                connectionStatus: .connected
            )
        case "markdown":
            MarkdownSurfaceView(
                surface: Self.markdownSurface,
                path: Self.markdownPath,
                loader: Self.fixtureLoader,
                connectionStatus: .connected
            )
        case "fallback":
            SurfaceFallbackCardView(
                surface: Self.browserSurface,
                workspaceName: "Todos",
                canOpenOnMac: true,
                openOnMac: { true }
            )
        case "picker":
            pickerPage
        default:
            TodoSurfaceView(
                surface: Self.todoSurface,
                todo: Self.todoSnapshot,
                allowsMutations: true,
                mutate: { _ in }
            )
        }
    }

    /// Hosts the production picker in a plain chrome bar; the menu itself is
    /// opened by tapping, exactly like the workspace toolbar entry point.
    private var pickerPage: some View {
        VStack {
            HStack {
                Spacer()
                TerminalPickerMenu(
                    value: TerminalPickerMenuValue(
                        liveTerminals: Self.fixtureTerminals,
                        liveSurfaces: [
                            Self.todoSurface,
                            Self.browserSurface,
                            Self.fileSurface,
                            Self.markdownSurface,
                        ],
                        snapshotRows: [],
                        selectedID: nil,
                        selectedMacSurfaceID: Self.todoSurface.id,
                        canCreateWorkspace: true,
                        hasActiveBrowser: false,
                        isChatMode: false
                    ),
                    actions: TerminalPickerMenuActions(
                        selectTerminal: { _ in },
                        selectMacSurface: { _ in },
                        createWorkspace: {},
                        createTerminal: {},
                        openBrowser: {},
                        selectBrowserStream: { _ in },
                        selectSimulatorStream: { _ in },
                        openTextSheet: {},
                        copyDebugLogs: {},
                        sendFeedback: {}
                    ),
                    terminalTheme: .monokai
                )
                .padding(12)
            }
            Spacer()
        }
        .background(Color(.systemBackground))
    }

    private static let textPath = "/Users/dev/notes/iosrf-demo.txt"
    private static let markdownPath = "/Users/dev/notes/iosrf-demo.md"

    private static let todoSurface = MobileSurfacePreview(
        id: "gallery-todo",
        kind: .todo,
        title: "Todos",
        todo: todoSnapshot
    )

    private static let fileSurface = MobileSurfacePreview(
        id: "gallery-file",
        kind: .filePreview,
        title: "iosrf-demo.txt",
        filePath: textPath
    )

    private static let markdownSurface = MobileSurfacePreview(
        id: "gallery-markdown",
        kind: .markdown,
        title: "iosrf-demo.md",
        filePath: markdownPath
    )

    private static let browserSurface = MobileSurfacePreview(
        id: "gallery-browser",
        kind: .browser,
        title: "cmux.com"
    )

    private static let todoSnapshot = MobileTodoSnapshot(
        status: .working,
        statusHidden: false,
        items: [
            MobileTodoItem(id: "1", text: "Render markdown natively on iOS", state: .completed, origin: .user),
            MobileTodoItem(id: "2", text: "Ship the UX round", state: .inProgress, origin: .user),
            MobileTodoItem(id: "3", text: "Polish todo rows and haptics", state: .inProgress, origin: .agent),
            MobileTodoItem(id: "4", text: "Verify dark and light appearance", state: .pending, origin: .user),
            MobileTodoItem(id: "5", text: "Hand off for dogfood", state: .pending, origin: .agent),
        ]
    )

    private static let fixtureTerminals = [
        MobileTerminalPreview(
            id: "gallery-terminal",
            name: "abdulazizalbahar@MacBook-Pro:~",
            currentDirectory: "~",
            isReady: true,
            isFocused: false
        )
    ]

    private static let fixtureLoader = ChatArtifactLoader(
        supportsArtifacts: true,
        scope: .panel(workspaceID: "gallery-ws", surfaceID: "gallery-surface"),
        stat: { path in
            ChatArtifactStat(
                exists: true,
                isDirectory: false,
                size: Int64(MacSurfaceGalleryFixtureBytes.body(for: path).count),
                modifiedAt: Date(timeIntervalSince1970: 1_753_800_000),
                kind: .text,
                mimeType: path.hasSuffix(".md") ? "text/markdown" : "text/plain"
            )
        },
        fetch: { path, progress in
            let data = MacSurfaceGalleryFixtureBytes.body(for: path)
            progress?(Int64(data.count), Int64(data.count))
            return data
        }
    )
}

/// Off-actor fixture bytes so the `@Sendable` loader closures can read them.
private enum MacSurfaceGalleryFixtureBytes {
    static let textBody = Data("""
    cmux iOS all-surfaces UX round — panel file preview fixture.

    This body streams through the panel-scoped artifact loader and renders in
    the embedded ChatArtifact text route: monospaced, selectable, scrollable.

    - filePreview surfaces render natively instead of an Open-on-Mac card.
    - Loading, missing-file, forbidden, and too-large states are designed.
    - The header shows the surface kind badge, title, and Open on Mac.
    """.utf8)

    static let markdownBody = Data("""
    # iosrf-demo

    Markdown panels now render **natively** on iOS through the shared
    document renderer.

    ## What changed

    - `markdown` surfaces fetch through the panel artifact lane.
    - UTF-8 decoding falls back to ISO-Latin-1 (café, naïve, ©).
    - Headings, lists, `inline code`, and block quotes match agent chat.

    > Read-only in v1: local links and images cannot resolve on the phone.

    ```swift
    let renderer = MacSurfaceRenderer.resolve(surface: surface)
    ```
    """.utf8)

    static func body(for path: String) -> Data {
        path.hasSuffix(".md") ? markdownBody : textBody
    }
}
#endif
