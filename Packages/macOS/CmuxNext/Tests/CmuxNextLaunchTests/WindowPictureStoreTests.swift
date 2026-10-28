import AppKit
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// One picture per window at quit: never of an incognito, full-screen, other-Space or
/// capture-hidden window; private files per profile, each save replacing the last; composed and encoded off the
/// main thread; the panes' pictures drawn over the root view's drawing and the privacy fills over everything; the
/// backdrop left out; and a meta whose layout digests are stable across processes and compared per region.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowPictureStoreTests {
    static let work = BackgroundWork(label: "test.window-pictures")
    static let allowed = WindowPictureStore.Eligibility(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: false,
                                                        hiddenFromCapture: false)
    static let background = WindowPictureStore.Color(red: 0, green: 0, blue: 1)
    /// An encoder that writes the same three bytes: the file tests need no HEIC encoder.
    static let fakeEncode: @Sendable (CGImage) -> Data? = { _ in Data([1, 2, 3]) }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "window-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func files(under directory: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// A `width` x `height` pixel image filled with `color` (transparent when nil).
    static func image(width: Int, height: Int, color: CGColor?) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let color {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(context.makeImage())
    }

    static func layout(workspaces: [String] = ["ws_a", "ws_b"], shown: String? = "ws_a",
                       tree: WindowPictureMeta.PaneTree = .split(vertical: false, ratio: 0.5, a: .leaf("1"),
                                                                 b: .stack(panes: ["2", "3"], expanded: "3"))) -> WindowPictureMeta.Layout {
        WindowPictureMeta.Layout(workspaces: workspaces, shown: shown, screens: [.init(id: "scr_1", tree: tree, zoomed: nil)])
    }

    static func meta(window: String = "w1", profile: String = "default") -> WindowPictureMeta {
        WindowPictureMeta(window: window, profile: profile, frame: CGRect(x: 100, y: 200, width: 1100, height: 720), screen: "DISPLAY-1",
                          scale: 2, appearance: NSAppearance.Name.darkAqua.rawValue, theme: WindowPictureMeta.fingerprint(["theme"]),
                          sidebarWidth: 240, build: "1.0 (1)", layout: layout(),
                          regions: [.init(kind: .pane, id: "tab_a", frame: CGRect(x: 240, y: 0, width: 860, height: 720))])
    }

    static func shot(window: String = "w1", profile: String = "default", eligibility: WindowPictureStore.Eligibility = allowed) throws -> WindowPictureStore.Shot {
        WindowPictureStore.Shot(eligibility: eligibility, base: try image(width: 20, height: 20, color: nil), size: CGSize(width: 10, height: 10),
                                layers: [], fills: [], background: background, meta: meta(window: window, profile: profile))
    }

    static func save(_ shots: [WindowPictureStore.Shot], in directory: URL) async {
        await WindowPictureStore(directory: directory, work: work, encode: fakeEncode).save(shots)
    }

    /// The acceptance: an incognito window never reaches the disk, nor a full-screen one, one on another Space, one
    /// not on screen or one hidden from screen capture; a picturable window beside them is written.
    @Test func incognitoAndUnpicturableWindowsAreNeverWritten() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        func refused(_ change: (inout WindowPictureStore.Eligibility) -> Void) -> WindowPictureStore.Eligibility {
            var eligibility = Self.allowed
            change(&eligibility)
            return eligibility
        }
        let refusals = [refused { $0.incognito = true }, refused { $0.fullScreen = true }, refused { $0.onActiveSpace = false },
                        refused { $0.onScreen = false }, refused { $0.hiddenFromCapture = true }]
        for (index, eligibility) in refusals.enumerated() {
            #expect(!eligibility.allowsPicture)
            await Self.save([try Self.shot(window: "refused\(index)", eligibility: eligibility)], in: directory)
            #expect(!FileManager.default.fileExists(atPath: directory.path), "an unpicturable window (\(eligibility)) was written")
        }
        await Self.save([try Self.shot(window: "incognito", eligibility: refusals[0]), try Self.shot(window: "w1")], in: directory)
        #expect(Self.files(under: directory) == ["default", "default/w1.heic", "default/w1.json"], "an incognito window was written")
    }

    @Test func picturesArePrivateAndPerProfile() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.save([try Self.shot(window: "w1", profile: "default"), try Self.shot(window: "w2", profile: "work")], in: directory)
        #expect(Self.files(under: directory) == ["default", "default/w1.heic", "default/w1.json", "work", "work/w2.heic", "work/w2.json"])
        #expect(Self.permissions(directory) == 0o700)
        #expect(Self.permissions(directory.appending(path: "default")) == 0o700)
        #expect(Self.permissions(directory.appending(path: "work")) == 0o700)
        for file in ["default/w1.heic", "default/w1.json", "work/w2.heic", "work/w2.json"] {
            #expect(Self.permissions(directory.appending(path: file)) == 0o600, "\(file) is not private")
        }
        let data = try Data(contentsOf: directory.appending(path: "default/w1.json"))
        #expect(try JSONDecoder().decode(WindowPictureMeta.self, from: data) == Self.meta(window: "w1"), "the meta did not come back as written")
    }

    /// A save replaces the last quit's set; a quit with no window to picture (or the feature off) leaves none.
    @Test func aSaveReplacesTheLastQuitsPictures() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.save([try Self.shot(window: "w1"), try Self.shot(window: "w2")], in: directory)
        await Self.save([try Self.shot(window: "w3")], in: directory)
        #expect(Self.files(under: directory) == ["default", "default/w3.heic", "default/w3.json"], "a picture of the last quit stayed")
        await WindowPictureStore(directory: directory, work: Self.work, encode: Self.fakeEncode).removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the last quit's pictures stayed")
    }

    /// A window or profile id that is not a plain slug never becomes a path, and one window is written once.
    @Test func unsafeIDsAndRepeatsAreSkipped() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.save([try Self.shot(window: "../escape"), try Self.shot(window: "w1", profile: "a/b"),
                         try Self.shot(window: "w1"), try Self.shot(window: "w1", profile: "work")], in: directory)
        #expect(Self.files(under: directory) == ["default", "default/w1.heic", "default/w1.json"])
    }

    /// The acceptance: composing and the encode run on the files lane, never on the main thread.
    @Test func theEncodeRunsOffTheMainThread() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (threads, thread) = AsyncStream.makeStream(of: Bool.self)
        let store = WindowPictureStore(directory: directory, work: Self.work) { _ in
            thread.yield(Thread.isMainThread)
            return Data([1])
        }
        await store.save([try Self.shot()])
        thread.finish()
        var onMain: [Bool] = []
        for await value in threads { onMain.append(value) }
        #expect(onMain == [false], "the encode ran on the main thread (or not once)")
    }

    /// The panes' pictures draw at their frames (points from the top-left) over the root view's drawing, the fills
    /// over them, and the backdrop's place stays clear.
    @Test func composingDrawsLayersThenFillsOverTheBase() throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let layers = [WindowPictureStore.Layer(image: try Self.image(width: 4, height: 4, color: red), frame: CGRect(x: 0, y: 0, width: 5, height: 5)),
                      WindowPictureStore.Layer(image: try Self.image(width: 4, height: 4, color: red), frame: CGRect(x: 5, y: 5, width: 5, height: 5))]
        let shot = WindowPictureStore.Shot(eligibility: Self.allowed, base: try Self.image(width: 20, height: 20, color: nil),
                                           size: CGSize(width: 10, height: 10), layers: layers,
                                           fills: [CGRect(x: 5, y: 5, width: 5, height: 5)], background: Self.background, meta: Self.meta())
        let picture = try #require(WindowPictureStore.compose(shot))
        #expect(picture.width == 20 && picture.height == 20, "the picture is not at the base's pixel size")
        let rep = NSBitmapImageRep(cgImage: picture)
        let topLeft = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(topLeft.redComponent > 0.9 && topLeft.alphaComponent > 0.9, "a pane's picture is not at its frame")
        let bottomRight = try #require(rep.colorAt(x: 17, y: 17)?.usingColorSpace(.sRGB))
        #expect(bottomRight.blueComponent > 0.9 && bottomRight.redComponent < 0.1, "a privacy fill did not cover the pane's picture")
        let topRight = try #require(rep.colorAt(x: 17, y: 2))
        #expect(topRight.alphaComponent < 0.01, "the backdrop's place is not clear")
    }

    /// HEIC keeps the picture's size and its clear pixels (the live backdrop shows through them at launch).
    @Test func heicKeepsSizeAndAlpha() throws {
        let picture = try Self.image(width: 64, height: 48, color: nil)
        let data = try #require(WindowPictureStore.heic(picture), "no HEIC encoder")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64 && decoded.height == 48)
        #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo), "the HEIC lost its alpha")
    }

    /// The capture draws the root view without its backdrop and shows the backdrop again at once.
    @Test func theCaptureLeavesTheBackdropOut() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let backdrop = FilledView(frame: root.bounds, color: .red)
        let left = FilledView(frame: NSRect(x: 0, y: 0, width: 20, height: 20), color: .green)
        root.addSubview(backdrop)
        root.addSubview(left)
        let picture = try #require(WindowPictureStore.capture(root, hiding: backdrop))
        #expect(!backdrop.isHidden, "the backdrop stayed hidden")
        let rep = NSBitmapImageRep(cgImage: picture)
        let leftColor = try #require(rep.colorAt(x: picture.width / 4, y: picture.height / 2)?.usingColorSpace(.sRGB))
        #expect(leftColor.greenComponent > 0.9 && leftColor.redComponent < 0.1, "the root view's content is missing")
        let rightColor = try #require(rep.colorAt(x: picture.width * 3 / 4, y: picture.height / 2))
        #expect(rightColor.alphaComponent < 0.01, "the backdrop was drawn into the picture")
    }

    /// A window's shot puts each pane's picture at its view, a placed picture within its content area and a fill at
    /// its view, all in points from the top-left; a hidden pane leaves nothing; the regions and the meta follow the
    /// window. An incognito window gives no shot.
    @Test func aShotPlacesEachPaneAtItsArea() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = root
        let backdrop = FilledView(frame: root.bounds, color: .red)
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 100))
        let areas = (0..<4).map { NSView(frame: NSRect(x: 50 + CGFloat($0) * 50, y: 0, width: 50, height: 100)) }
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 80))
        let secret = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        areas[0].addSubview(surface)
        areas[2].addSubview(secret)
        areas[3].isHidden = true
        for view in [backdrop, sidebar] + areas { root.addSubview(view) }
        window.orderFrontRegardless()
        let image = try Self.image(width: 4, height: 4, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let panes = [WindowPictureStore.Pane(key: "tab_a", area: areas[0], content: .picture(image, of: surface)),
                     WindowPictureStore.Pane(key: "tab_b", area: areas[1], content: .placed(image, at: CGRect(x: 10, y: 5, width: 20, height: 20))),
                     WindowPictureStore.Pane(key: "tab_c", area: areas[2], content: .fill(secret)),
                     WindowPictureStore.Pane(key: "tab_d", area: areas[3], content: .fill(areas[3]))]
        let facts = WindowPictureStore.Window(id: "w1", profile: "default", incognito: false, theme: "t", background: Self.background,
                                              build: "1.0 (1)", layout: Self.layout(), screen: nil)
        let shot = try #require(WindowPictureStore.shot(of: window, root: root, backdrop: backdrop, sidebar: sidebar, panes: panes, facts: facts),
                                "a picturable window gave no shot")
        #expect(shot.layers.map(\.frame) == [CGRect(x: 50, y: 20, width: 50, height: 80), CGRect(x: 110, y: 5, width: 20, height: 20)])
        #expect(shot.fills == [CGRect(x: 150, y: 50, width: 50, height: 50)], "a fill is not at its view, or a hidden pane left one")
        #expect(shot.meta.regions.map(\.id) == ["tab_a", "tab_b", "tab_c", "sidebar"], "a hidden pane left a region")
        #expect(shot.meta.regions.first?.frame == CGRect(x: 50, y: 0, width: 50, height: 100))
        #expect(shot.meta.sidebarWidth == 50 && shot.meta.window == "w1" && shot.meta.frame == window.frame)
        #expect(shot.size == root.bounds.size)
        #expect(!backdrop.isHidden)
        let incognito = WindowPictureStore.Window(id: "w1", profile: "default", incognito: true, theme: "t", background: Self.background,
                                                  build: "1.0 (1)", layout: Self.layout(), screen: nil)
        #expect(WindowPictureStore.shot(of: window, root: root, backdrop: backdrop, sidebar: sidebar, panes: panes, facts: incognito) == nil,
                "an incognito window gave a shot")
    }

    /// The layout digests are SHA-256, the same in every process (pinned), and each region's changes only its own.
    @Test func layoutDigestsAreStableAndPerRegion() {
        let layout = Self.layout()
        #expect(layout.sidebar == "dcb827a2c791947c8ea7c970fe880387bd673ce04318be6759e410b23d791632")
        #expect(layout.content == "1da2c5b652e8c9f24c1dbad2613665433f6101a6242ecf5773e278026b018b41")
        let reordered = Self.layout(workspaces: ["ws_b", "ws_a"])
        #expect(reordered.sidebar != layout.sidebar && reordered.content == layout.content)
        let resplit = Self.layout(tree: .split(vertical: true, ratio: 0.5, a: .leaf("1"), b: .stack(panes: ["2", "3"], expanded: "3")))
        #expect(resplit.sidebar == layout.sidebar && resplit.content != layout.content)
        let nudged = Self.layout(tree: .split(vertical: false, ratio: 0.5001, a: .leaf("1"), b: .stack(panes: ["2", "3"], expanded: "3")))
        #expect(nudged == layout, "a ratio within a thousandth is another layout")
        let otherShown = Self.layout(shown: "ws_b")
        #expect(otherShown.sidebar != layout.sidebar && otherShown.content != layout.content)
    }

    /// The theme's fingerprint names each field and token in a fixed order and is pinned, so the same theme gives the
    /// same digest in every launch (a dictionary's order is seeded per process). Dracula's input and tokens are
    /// schemas/theme/app-theme-vectors.json's.
    @Test func theThemeFingerprintIsTheSameInEveryLaunch() throws {
        let palette = ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                       "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"].compactMap { ThemeRGB(cssHex: $0) }
        let input = ThemeInput(background: try #require(ThemeRGB(cssHex: "#282a36")), foreground: try #require(ThemeRGB(cssHex: "#f8f8f2")),
                               palette: palette)
        let app = AppTheme.derive(from: input)
        #expect(WindowPictureMeta.themeParts(input: input, app: app) == [
            "input", "background=#282A36", "foreground=#F8F8F2", "palette=16",
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
            "selectionBackground=-", "selectionForeground=-", "cursor=-", "opacity=1.0", "blur=0", "accent=neutral", "accentColor=-",
            "app", "isDark=true",
            "window=#282A36", "sidebar=#30323E", "content=#282A36", "elevated=#383944", "control=#3D3F49", "hover=#343641",
            "pressed=#41434D", "selection=#5E5F68", "separator=#43454E", "controlStroke=#878A8E", "text=#F8F8F2",
            "textSecondary=#D8DAD9", "icon=#BABABA", "accent=#F7F7F7", "onAccent=#282A36", "accentText=#F7F7F7",
            "focusRing=#F7F7F7", "danger=#FF7A74", "warning=#F1FA8C", "success=#50FA7B",
        ])
        let pinned = "64b38dc3243b9d2c325a3c10b3ef5a2b4eeb68720a2c5c4bf33aecf031520010"
        #expect(WindowPictureMeta.themeFingerprint(input: input, app: app) == pinned)
        #expect(WindowPictureMeta.themeFingerprint(input: input, app: AppTheme.derive(from: input)) == pinned)
        var edited = input
        edited.cursor = ThemeRGB(hex: 0xFF0000)
        #expect(WindowPictureMeta.themeFingerprint(input: edited, app: AppTheme.derive(from: edited)) != pinned, "a theme edit kept the fingerprint")
    }

    /// A window with no pane (a top page or the empty state fills its content area) gives a shot of what AppKit
    /// drew: the sidebar's region only, no layer and no fill.
    @Test func aWindowWithNoPaneGivesAShot() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = root
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 100))
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        let layout = WindowPictureMeta.Layout(workspaces: ["ws_a"], shown: "top:home", screens: [])
        let facts = WindowPictureStore.Window(id: "w1", profile: "default", incognito: false, theme: "t", background: Self.background,
                                              build: "1.0 (1)", layout: layout, screen: nil)
        let shot = try #require(WindowPictureStore.shot(of: window, root: root, backdrop: nil, sidebar: sidebar, panes: [], facts: facts),
                                "a window with no pane gave no shot")
        #expect(shot.layers.isEmpty && shot.fills.isEmpty)
        #expect(shot.meta.regions.map(\.id) == ["sidebar"])
        #expect(shot.meta.layout == layout)
    }

    /// A window with no workspace content still leaves a picture: a top page (its workspace's content parked) or the
    /// empty state, with no pane tree; a window between states (a workspace not mounted yet, a Cloud workspace being
    /// created) leaves none.
    @Test func theContentAreaOfAWindowWithNoWorkspaceContent() throws {
        typealias Area = WindowPictureMeta.ContentArea
        let screens = [WindowPictureMeta.Screen(id: "scr_1", tree: .leaf("1"), zoomed: nil)]
        let home = try #require(Area(page: "home", workspaceID: "ws_a", cloudCreating: false, contentShown: false))
        #expect(home == .page("home"))
        #expect(home.layout(workspaces: ["ws_a"], screens: screens) == WindowPictureMeta.Layout(workspaces: ["ws_a"], shown: "top:home", screens: []))
        let settings = try #require(Area(page: "page:settings", workspaceID: nil, cloudCreating: true, contentShown: false))
        #expect(settings.layout(workspaces: [], screens: []).content != home.layout(workspaces: [], screens: []).content,
                "two pages have the same content layout")
        let empty = try #require(Area(page: nil, workspaceID: nil, cloudCreating: false, contentShown: false))
        #expect(empty == .empty)
        #expect(empty.layout(workspaces: [], screens: screens) == WindowPictureMeta.Layout(workspaces: [], shown: nil, screens: []))
        let workspace = try #require(Area(page: nil, workspaceID: "ws_a", cloudCreating: false, contentShown: true))
        #expect(workspace.layout(workspaces: ["ws_a"], screens: screens) == WindowPictureMeta.Layout(workspaces: ["ws_a"], shown: "ws_a", screens: screens))
        #expect(Area(page: nil, workspaceID: "ws_a", cloudCreating: false, contentShown: false) == nil, "an unmounted workspace left a picture")
        #expect(Area(page: nil, workspaceID: "ws_a", cloudCreating: true, contentShown: true) == nil, "a Cloud workspace being created left a picture")
        #expect(Area(page: nil, workspaceID: nil, cloudCreating: true, contentShown: false) == nil)
    }

    /// A launch compares every field; frames and the sidebar width within half a point.
    @Test func mismatchesNameEachDifferingField() {
        let meta = Self.meta()
        #expect(meta.mismatches(meta).isEmpty)
        var moved = meta
        moved.frame.origin.x += 0.25
        moved.sidebarWidth += 0.25
        #expect(meta.mismatches(moved).isEmpty, "a sub-point difference is a mismatch")
        var changed = meta
        changed.frame.size.width += 20
        changed.scale = 1
        changed.appearance = NSAppearance.Name.aqua.rawValue
        changed.layout = Self.layout(workspaces: ["ws_a"])
        #expect(meta.mismatches(changed) == [.frame, .scale, .appearance, .sidebarLayout])
    }
}

/// A view that fills itself with one color when AppKit draws it.
private final class FilledView: NSView {
    let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
