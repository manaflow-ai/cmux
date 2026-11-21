#if os(iOS)
import CmuxMobileModel
import Observation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

// iOS reliability matrix, axis `device` (cmux-next-ios/reliability-matrix/cells.json):
// the Workspaces list and an open workspace's composer on each device shape, and the
// changes a session lives through (a fold, a rotation, a text size, dark mode), each as a
// cell instead of a manual pass.
//
// There is no simulator for a foldable iPhone ("make it work for iPhone Duo as well", Leo,
// 2026-11-10). A fold is emulated the way the system delivers it to the app: the window
// changes size and its horizontal size class goes from compact to regular (unfolded) and
// back, mid-session. The session must keep the workspace that is open, the list's scroll
// position and the composer's text. An iPad and a landscape iPhone are the same kind of
// window change, so they run on the CI's iPhone simulator too.
//
// The harness is the shell's own Workspaces stack (Screens.swift: a typed
// `NavigationStack` over `WorkspacesList`, a workspace page pushed on its path) with the
// agent chat's composer field on the page, in a real window.

@MainActor @Observable
final class DeviceAxisSession {
    let store: AppStore
    let creator: WorkspaceCreator
    var path: [Workspace] = []
    var draft = ""
    var focused = false

    init() {
        let store = AppStore.mock(tabMemory: .inMemory())
        // Enough rows that every window shape scrolls.
        let now = Date()
        store.workspaces += (0 ..< 60).map { index in
            Workspace(id: "ws-axis-\(index)", macID: "mac-studio", title: "axis \(index)", directory: "~/axis/\(index)",
                      branch: "main", tabs: [WorkspaceTab(id: "t-axis-\(index)", kind: .terminal, title: "zsh", subtitle: "~/axis/\(index)")],
                      lastActivityAt: now.addingTimeInterval(-Double(index + 30) * 600))
        }
        self.store = store
        creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
    }
}

struct DeviceAxisHarness: View {
    @Bindable var session: DeviceAxisSession

    var body: some View {
        NavigationStack(path: $session.path) {
            WorkspacesList(store: session.store, creator: session.creator) { session.path.append($0) }
                .navigationDestination(for: Workspace.self) { workspace in
                    VStack(spacing: 0) {
                        Text(workspace.title)
                        Spacer(minLength: 0)
                        ChatComposerField(text: $session.draft, placeholder: "Message", isFocused: $session.focused, onSend: {})
                            .padding(12)
                    }
                }
        }
    }
}

/// A window shape: its size in points and its size classes.
struct DeviceShape: CustomStringConvertible {
    let name: String
    let size: CGSize
    let horizontal: UIUserInterfaceSizeClass
    let vertical: UIUserInterfaceSizeClass
    var description: String { "\(name) \(Int(size.width))x\(Int(size.height))" }

    static let iPhone = DeviceShape(name: "iphone", size: CGSize(width: 402, height: 874), horizontal: .compact, vertical: .regular)
    static let iPhoneLandscape = DeviceShape(name: "iphone-landscape", size: CGSize(width: 874, height: 402), horizontal: .compact, vertical: .compact)
    static let iPad = DeviceShape(name: "ipad", size: CGSize(width: 820, height: 1180), horizontal: .regular, vertical: .regular)
    /// A foldable's cover screen: narrow and tall.
    static let folded = DeviceShape(name: "foldable-folded", size: CGSize(width: 344, height: 882), horizontal: .compact, vertical: .regular)
    /// Its inner screen open: close to square, regular width.
    static let unfolded = DeviceShape(name: "foldable-unfolded", size: CGSize(width: 884, height: 1104), horizontal: .regular, vertical: .regular)
}

@MainActor
final class DeviceAxisWindow {
    let session = DeviceAxisSession()
    let window: UIWindow
    let host: UIHostingController<DeviceAxisHarness>

    init(_ shape: DeviceShape, style: UIUserInterfaceStyle = .unspecified, text: UIContentSizeCategory? = nil) {
        host = UIHostingController(rootView: DeviceAxisHarness(session: session))
        window = UIWindow(frame: CGRect(origin: .zero, size: shape.size))
        if style != .unspecified { window.traitOverrides.userInterfaceStyle = style }
        if let text { window.traitOverrides.preferredContentSizeCategory = text }
        apply(shape)
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    func apply(_ shape: DeviceShape) {
        window.frame = CGRect(origin: .zero, size: shape.size)
        window.traitOverrides.horizontalSizeClass = shape.horizontal
        window.traitOverrides.verticalSizeClass = shape.vertical
    }

    /// A few display frames: SwiftUI's updates and UIKit's layout both run.
    func settle(_ frames: Int = 10) async {
        for _ in 0 ..< frames {
            host.view.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Changes the window as a fold, unfold or rotation does, then lets it lay out.
    func change(to shape: DeviceShape) async {
        apply(shape)
        await settle(20)
    }

    func close() { window.isHidden = true }

    var list: UICollectionView? {
        Self.find(UICollectionView.self, in: window) { $0.accessibilityIdentifier == "workspaces.list" && $0.window != nil && !$0.isHidden }
    }

    var composer: ChatComposerTextView? {
        Self.find(ChatComposerTextView.self, in: window) { $0.window != nil }
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool) -> T? {
        if let found = view as? T, match(found) { return found }
        for child in view.subviews {
            if let found = find(type, in: child, where: match) { return found }
        }
        return nil
    }

    /// Waits until the list has laid out rows (the first layout can take a few frames).
    func listWithRows() async throws -> UICollectionView {
        for _ in 0 ..< 120 {
            if let list, !list.indexPathsForVisibleItems.isEmpty { return list }
            await settle(1)
        }
        return try #require(list, "no Workspaces list in the window")
    }

    /// The row at the top of the list's visible area (the reader's scroll position).
    func topRow(_ list: UICollectionView) -> IndexPath? {
        let top = list.contentOffset.y + list.adjustedContentInset.top
        for step in 0 ..< 20 {
            let point = CGPoint(x: list.bounds.midX, y: top + 4 + CGFloat(step) * 6)
            if let path = list.indexPathForItem(at: point) { return path }
        }
        return nil
    }

    /// Opens the workspace the way a row's tap does, and waits for its composer.
    func open(_ workspace: Workspace) async throws -> ChatComposerTextView {
        session.path.append(workspace)
        for _ in 0 ..< 120 {
            if let composer { return composer }
            await settle(1)
        }
        return try #require(composer, "the workspace page has no composer")
    }
}

/// What the layout must hold at every shape: the list fills the window's width and no row
/// leaves it sideways.
@MainActor
private func expectListFits(_ list: UICollectionView, in window: UIWindow, _ shape: DeviceShape,
                            sourceLocation: SourceLocation = #_sourceLocation) {
    let width = window.bounds.width
    let frame = list.convert(list.bounds, to: window)
    #expect(abs(frame.width - width) <= 1, "\(shape): the list is \(frame.width) pt wide in a \(width) pt window", sourceLocation: sourceLocation)
    let cells = list.visibleCells
    #expect(!cells.isEmpty, "\(shape): no rows on screen", sourceLocation: sourceLocation)
    for cell in cells {
        let cellFrame = cell.convert(cell.bounds, to: window)
        #expect(cellFrame.minX >= -0.5 && cellFrame.maxX <= width + 0.5,
                "\(shape): a row runs off the window, \(cellFrame) in \(width) pt", sourceLocation: sourceLocation)
        #expect(cellFrame.height > 0, "\(shape): a row with no height", sourceLocation: sourceLocation)
    }
}

/// The composer is inside the window, wide enough to type in.
@MainActor
private func expectComposerOnScreen(_ composer: UIView, in window: UIWindow, _ shape: DeviceShape,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
    let frame = composer.convert(composer.bounds, to: window)
    let bounds = window.bounds.insetBy(dx: -0.5, dy: -0.5)
    #expect(bounds.contains(frame), "\(shape): the composer \(frame) is outside the window \(window.bounds)", sourceLocation: sourceLocation)
    #expect(frame.width >= min(200, window.bounds.width / 2), "\(shape): the composer is \(frame.width) pt wide", sourceLocation: sourceLocation)
}

private func report(_ cell: String, _ variant: String, _ fields: [String: Any]) {
    var line = fields
    line["cell"] = cell
    line["variant"] = variant
    if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print("MATRIX \(text)")
    }
}

@MainActor @Suite(.serialized) struct DeviceAxesTests {
    /// One shape: the list lays out inside the window, and a workspace's composer is on screen.
    private func layoutCell(_ cell: String, _ shape: DeviceShape) async throws {
        let device = DeviceAxisWindow(shape)
        defer { device.close() }
        let list = try await device.listWithRows()
        expectListFits(list, in: device.window, shape)
        let workspace = try #require(device.session.store.activeWorkspaces.first)
        let composer = try await device.open(workspace)
        expectComposerOnScreen(composer, in: device.window, shape)
        report(cell, shape.name, ["width": Int(shape.size.width), "height": Int(shape.size.height), "rows": list.visibleCells.count])
    }

    @Test func cellDeviceIPhone() async throws { try await layoutCell("device_iphone", .iPhone) }

    /// The app is iPhone-only (TARGETED_DEVICE_FAMILY 1): a real iPad runs it in iPhone
    /// compatibility mode. The cell holds the layout at an iPad's window and size classes for
    /// the day it runs natively.
    @Test func cellDeviceIPad() async throws { try await layoutCell("device_ipad", .iPad) }

    @Test func cellDeviceFoldableFolded() async throws { try await layoutCell("device_foldable_folded", .folded) }

    @Test func cellDeviceFoldableUnfolded() async throws { try await layoutCell("device_foldable_unfolded", .unfolded) }

    /// A session through `shapes` in order (the first is where it starts): at each change the
    /// list's scroll position, the open workspace and the composer's text survive, and the
    /// layout holds at the new shape.
    private func survives(_ cell: String, _ shapes: [DeviceShape]) async throws {
        let device = DeviceAxisWindow(shapes[0])
        defer { device.close() }

        // The list, scrolled down.
        let list = try await device.listWithRows()
        let target = min(600, max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom))
        try #require(target > 100, "the list does not scroll: \(list.contentSize.height) in \(list.bounds.height)")
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: target - list.adjustedContentInset.top), animated: false)
        await device.settle()
        let top = try #require(device.topRow(list), "no row at the top of the list")
        for shape in shapes.dropFirst() {
            await device.change(to: shape)
            let now = try await device.listWithRows()
            expectListFits(now, in: device.window, shape)
            #expect(device.topRow(now) == top, "\(shape): the list's top row moved from \(top) to \(String(describing: device.topRow(now)))")
        }

        // Back at the first shape, a workspace open with half a prompt typed.
        await device.change(to: shapes[0])
        let workspace = try #require(device.session.store.activeWorkspaces.first)
        let composer = try await device.open(workspace)
        composer.insertText("half a prompt")
        await device.settle()
        try #require(device.session.draft == "half a prompt", "typing did not reach the draft: '\(device.session.draft)'")
        for shape in shapes.dropFirst() + [shapes[0]] {
            await device.change(to: shape)
            #expect(device.session.path.map(\.id) == [workspace.id],
                    "\(shape): the open workspace became \(device.session.path.map(\.id))")
            #expect(device.session.draft == "half a prompt", "\(shape): the draft became '\(device.session.draft)'")
            let field = try #require(device.composer, "\(shape): the composer is gone")
            #expect(field.text == "half a prompt", "\(shape): the composer shows '\(field.text ?? "")'")
            expectComposerOnScreen(field, in: device.window, shape)
        }
        report(cell, shapes.map(\.name).joined(separator: ">"), ["top_row": top.item, "section": top.section])
    }

    /// Folded, unfolded mid-session, folded again.
    @Test func cellDeviceFoldMidSession() async throws {
        try await survives("device_fold_mid_session", [.folded, .unfolded, .folded])
    }

    /// Portrait, landscape (compact height), portrait. The app's own window stays portrait
    /// outside Screen Sharing (`ScreenSharingOrientation`); this is the window a rotation
    /// gives the app where it turns.
    @Test func cellDeviceRotation() async throws {
        try await survives("device_rotation", [.iPhone, .iPhoneLandscape, .iPhone])
    }

    /// Dynamic Type at its largest (AX5, accessibilityExtraExtraExtraLarge): the rows grow
    /// with their text and stay inside the window; the composer stays on screen.
    @Test func cellDeviceDynamicTypeAX5() async throws {
        let standard = DeviceAxisWindow(.iPhone, text: .large)
        let standardList = try await standard.listWithRows()
        let standardHeight = standardList.visibleCells.map(\.bounds.height).max() ?? 0
        standard.close()

        let device = DeviceAxisWindow(.iPhone, text: .accessibilityExtraExtraExtraLarge)
        defer { device.close() }
        let list = try await device.listWithRows()
        expectListFits(list, in: device.window, .iPhone)
        let height = list.visibleCells.map(\.bounds.height).max() ?? 0
        #expect(height > standardHeight * 1.5, "AX5 rows are \(height) pt, Large rows \(standardHeight) pt: the text did not grow")
        let workspace = try #require(device.session.store.activeWorkspaces.first)
        let composer = try await device.open(workspace)
        expectComposerOnScreen(composer, in: device.window, .iPhone)
        report("device_dynamic_type_ax5", "ax5", ["row_pt": Double(height), "large_row_pt": Double(standardHeight)])
    }

    /// Dark mode: the list and the composer take the dark appearance (the composer's text
    /// resolves light), and the layout is the same as in light.
    @Test func cellDeviceDark() async throws {
        let device = DeviceAxisWindow(.iPhone, style: .dark)
        defer { device.close() }
        let list = try await device.listWithRows()
        expectListFits(list, in: device.window, .iPhone)
        #expect(list.traitCollection.userInterfaceStyle == .dark, "the list is \(list.traitCollection.userInterfaceStyle.rawValue), not dark")
        let workspace = try #require(device.session.store.activeWorkspaces.first)
        let composer = try await device.open(workspace)
        expectComposerOnScreen(composer, in: device.window, .iPhone)
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        (composer.textColor ?? .label).resolvedColor(with: composer.traitCollection).getWhite(&white, alpha: &alpha)
        #expect(white > 0.8, "the composer's text resolves to white \(white) in dark mode")
        report("device_dark", "dark", ["composer_text_white": Double(white)])
    }
}
#endif
